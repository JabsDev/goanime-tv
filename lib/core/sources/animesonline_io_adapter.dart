import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';
import 'cdn_resolver.dart' show probeMediaUrl;

/// AnimesOnline IO (`https://animesonline.io`, Tsundere theme) — PT-BR.
///
/// Search and episode listing are plain HTML; video goes through the
/// `anidrive` token player:
///
///  1. episode page `/NNNNN/` embeds a base64 `<iframe ... anidrive...token/>`;
///  2. the token page (cookies + Referer required) runs an obfuscated
///     array+permute+XOR bootstrap whose payload holds the jwplayer
///     `sources:[{file:"https://redirector.googlevideo.com/..."}`;
///  3. that file URL (H.264 `itag=22`) is probed with a range request.
///
/// The googlevideo URL is short-lived and IP-sensitive; like every other
/// source it resolves on demand, and an unplayable URL degrades to an empty
/// result (honest `matchedUnavailable`), never a crash.
class AnimesOnlineIoAdapter extends AnimeSourceAdapter {
  final http.Client? _client;

  AnimesOnlineIoAdapter({http.Client? client}) : _client = client;

  static const _base = 'https://animesonline.io';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) {
      return _client.get(uri, headers: headers);
    }
    return apiClient.get(uri, headers: headers);
  }

  @override
  AnimeSource get source => AnimeSource.animesOnlineIo;

  /// Desligada no fan-out: busca/episódios/desembaralho funcionam, mas o
  /// file final do Google Video dá 403 fora do fluxo mediado pelo site
  /// (IP-bound + service worker; provado no datacenter E no residencial).
  /// Mantida + testada para religar se o gate cair.
  @override
  bool get implemented => false;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    final url =
        Uri.parse('$_base/?s=${Uri.encodeQueryComponent(TextUtils.cleanSearchQuery(query))}');
    try {
      http.Response res;
      try {
        res = await _httpGet(url, headers: {'User-Agent': _ua});
      } on TimeoutException {
        res = await _httpGet(url, headers: {'User-Agent': _ua});
      }
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final list = <Anime>[];
      final seen = <String>{};
      for (final a in doc.querySelectorAll('article.bs .bsx a')) {
        final href = a.attributes['href'] ?? '';
        if (href.isEmpty || !href.contains('/anime/')) continue;
        if (!seen.add(href)) continue;
        final img = a.querySelector('img');
        final name = TextUtils.cleanTitle(
          a.attributes['title']?.trim() ??
              a.querySelector('.tt')?.text.trim() ??
              href.split('/').where((s) => s.isNotEmpty).last,
        );
        if (name.isEmpty) continue;
        list.add(Anime(
          name: name,
          url: href,
          source: source,
          fallbackImageUrl:
              img?.attributes['data-src'] ?? img?.attributes['src'],
        ));
      }
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No results found',
          source: source,
        ));
      }
      return ScraperResult.success(list);
    } on TimeoutException {
      return ScraperResult.failure(TimeoutError(
        message: 'Search timed out',
        source: source,
      ));
    } catch (e) {
      debugPrint('[AnimesOnlineIO] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Unexpected error: $e',
        source: source,
      ));
    }
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    if (anime.url.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'No anime URL provided',
        source: source,
      ));
    }
    try {
      final res = await _httpGet(Uri.parse(anime.url), headers: {
        'User-Agent': _ua,
      });
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final byNumber = <int, String>{};
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = a.attributes['href'] ?? '';
        // Numeric episode pages (`/15859/`, absolute or relative);
        // pagination (`/anime/x/page/N`) never matches this shape.
        final m =
            RegExp(r'^(?:https?://[^/]+)?/(\d+)/$').firstMatch(href);
        if (m == null) continue;
        // Só vale o número exibido (`.epl-num`): os dígitos do href são IDs
        // internos do post (ex. `/54365/`) e widgets laterais injetam links
        // numéricos sem episódio — aceitar o fallback poluía a grade com
        // EPs fantasmas (visto ao vivo: EP 16916).
        final numEl = a.querySelector('.epl-num');
        final n = int.tryParse((numEl?.text ?? '').trim());
        if (n == null) continue;
        final abs = href.startsWith('http') ? href : '$_base${m.group(0)}';
        byNumber.putIfAbsent(n, () => abs);
      }
      if (byNumber.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed',
          source: source,
        ));
      }
      final numbers = byNumber.keys.toList()..sort();
      return ScraperResult.success([
        for (final n in numbers)
          Episode(number: '$n', url: byNumber[n]!, owner: anime),
      ]);
    } catch (e) {
      debugPrint('[AnimesOnlineIO] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final pageRes = await _httpGet(Uri.parse(episode.url), headers: {
        'User-Agent': _ua,
        'Referer': '$_base/',
      });
      if (pageRes.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${pageRes.statusCode}',
          source: source,
        ));
      }
      final tokenUrl = _tokenUrl(pageRes.body);
      if (tokenUrl == null) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No player token in episode page',
          source: source,
        ));
      }
      final cookie = _cookies(pageRes.headers);
      final tokRes = await _httpGet(Uri.parse(tokenUrl), headers: {
        'User-Agent': _ua,
        'Referer': episode.url,
        if (cookie.isNotEmpty) 'Cookie': cookie,
        'Accept': 'text/html',
      });
      if (tokRes.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Token page non-200: ${tokRes.statusCode}',
          source: source,
        ));
      }
      final file = _playerFile(tokRes.body);
      if (file == null) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No media URL in player payload',
          source: source,
        ));
      }
      if (await probeMediaUrl(Uri.parse(file),
              client: _client,
              headers: {'User-Agent': _ua, 'Referer': tokenUrl}) <
          0) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Media URL did not answer the range probe',
          source: source,
        ));
      }
      return ScraperResult.success([
        VideoSource(
          url: file,
          quality: 'Auto',
          headers: {'User-Agent': _ua, 'Referer': tokenUrl},
        ),
      ]);
    } catch (e) {
      debugPrint('[AnimesOnlineIO] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Base64 `<iframe ... anidrive.../token/...>` embedded in the episode page.
  @visibleForTesting
  static String? tokenUrl(String episodeHtml) => _tokenUrl(episodeHtml);

  static String? _tokenUrl(String episodeHtml) {
    for (final m in RegExp(r'value="(PGl[^"]+)"').allMatches(episodeHtml)) {
      try {
        final decoded =
            utf8.decode(base64.decode(m.group(1)!), allowMalformed: true);
        final src =
            RegExp(r'src="(https://[^"]+)"').firstMatch(decoded)?.group(1);
        if (src != null && src.isNotEmpty) return src;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// `name=value` pairs from `set-cookie` to replay on the token request.
  /// Unknown pairs (e.g. stray `expires`) are harmless — the server ignores
  /// what it doesn't know.
  @visibleForTesting
  static String cookies(Map<String, String> headers) => _cookies(headers);

  static const _cookieAttrs = {
    'path',
    'expires',
    'domain',
    'max-age',
    'samesite',
  };

  static String _cookies(Map<String, String> headers) {
    final raw = headers['set-cookie'];
    if (raw == null || raw.isEmpty) return '';
    final pairs = RegExp(r'([\w\-\$]+)=([^;,]*)')
        .allMatches(raw)
        .map((m) => MapEntry(m.group(1)!, m.group(2)!))
        .where((e) =>
            e.value.isNotEmpty &&
            !_cookieAttrs.contains(e.key.toLowerCase()))
        .map((e) => '${e.key}=${e.value}')
        .toSet();
    return pairs.join('; ');
  }

  /// De-obfuscates the anidrive bootstrap scripts (array + index permutation
  /// + XOR key) and returns the jwplayer `file` URL, or null.
  @visibleForTesting
  static String? playerFile(String tokenHtml) => _playerFile(tokenHtml);

  static String? _playerFile(String tokenHtml) {
    final payloads = _descrambled(tokenHtml);
    for (final p in payloads) {
      final f = RegExp(r'"file":"([^"]+)"').firstMatch(p)?.group(1);
      if (f != null && f.startsWith('http')) return f;
    }
    return null;
  }

  static List<String> _descrambled(String html) {
    final out = <String>[];
    final callRe = RegExp(
      r'\}\s*_\w+\(\[(.*?)\],\[(.*?)\],"([^"]+)"\)',
      dotAll: true,
    );
    for (final call in callRe.allMatches(html)) {
      try {
        final items =
            RegExp(r'"([^"]+)"').allMatches(call.group(1)!).map((m) => m.group(1)!).toList();
        final perm = RegExp(r'\d+')
            .allMatches(call.group(2)!)
            .map((m) => int.parse(m.group(0)!))
            .toList();
        if (items.isEmpty || perm.isEmpty) continue;
        final joined = StringBuffer();
        for (final i in perm) {
          if (i < 0 || i >= items.length) throw const FormatException('bad perm');
          joined.write(items[i]);
        }
        final raw = base64.decode(joined.toString().replaceAll(RegExp(r'\s'), ''));
        final key = base64.decode(call.group(3)!);
        final xored =
            List<int>.generate(raw.length, (i) => raw[i] ^ key[i % key.length]);
        out.add(utf8.decode(xored, allowMalformed: true));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    final report = AvailabilityReport(source: source, animeName: animeName);
    try {
      final result = await search(animeName);
      switch (result) {
        case Success(data: final animes):
          if (animes.isNotEmpty) {
            report.status = AvailabilityStatus.available;
            return report;
          }
        case Failure(error: final err):
          report.status = AvailabilityStatus.notFound;
          report.reason = err.message;
        case Loading():
          break;
      }
    } on Exception catch (e) {
      report.status = AvailabilityStatus.exception;
      report.reason = 'Exception: $e';
    }
    return report;
  }
}
