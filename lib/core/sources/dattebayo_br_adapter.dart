import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' show Document;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';
import 'cdn_resolver.dart' show probeMediaUrl;

/// Dattebayo BR (`https://www.dattebayo-br.com`) — PT-BR, separado em
/// legendado (`/animes/<slug>`) e dublado (`/anime-dublado/<slug>`).
///
/// Fluxo (verificado ao vivo 08/11/2026, Slime S4E23):
///  1. busca `GET /busca?busca=<q>&page=N` → `div.ultimosAnimesHomeItem`;
///  2. página do anime lista `div.ultimosEpisodiosHomeItem` (`/videos/<id>`),
///     paginada em `/page/N`;
///  3. a página do episódio traz até três `<div class="playerContainer">`
///     (SD/HD/FULLHD) com `var vid = '<mp4 no R2>'`. O mp4 cru responde 403:
///     o site pede uma assinatura em `GET ads.animeyabu.net?url=<mp4>` e
///     concatena `publicidade` à URL (S3 presigned, válida ~1 h).
///
/// O player resolve on-demand (a URL expira), então nada é cacheado. O
/// resultado só entra no seletor depois do probe 206.
class DattebayoBrAdapter extends AnimeSourceAdapter {
  static const _base = 'https://www.dattebayo-br.com';
  static const _ads = 'https://ads.animeyabu.net';

  final http.Client? _client;

  DattebayoBrAdapter({http.Client? client}) : _client = client;

  @override
  AnimeSource get source => AnimeSource.dattebayoBr;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  static const _headers = {
    'User-Agent': _ua,
    'Accept': '*/*',
    'Accept-Language': 'pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7',
    'X-Requested-With': 'XMLHttpRequest',
  };

  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) return _client.get(uri, headers: headers);
    return apiClient.get(uri, headers: headers);
  }

  @override
  Future<Anime?> resolveAnime(Anime animeRef) async {
    // O catálogo do site usa romaji ("Tensei Shitara Slime Datta Ken 4th
    // Season"); o AniList pode entregar inglês. Tenta o inglês primeiro e cai
    // para o nome dado, como AnimeFire/AnimesOnline.
    final queries = <String>{
      if (animeRef.englishName != null && animeRef.englishName!.isNotEmpty)
        animeRef.englishName!,
      animeRef.name,
    };
    for (final q in queries) {
      final result = await search(TextUtils.cleanSearchQuery(q));
      switch (result) {
        case Success(data: final candidates):
          final valid = candidates.where((a) => a.url.isNotEmpty).toList();
          if (valid.isEmpty) continue;
          return AnimeSourceAdapter.pinSeasonPage(
              q, valid, source, animeRef.url);
        case Failure():
        case Loading():
          continue;
      }
    }
    return null;
  }

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final q = Uri.encodeQueryComponent(
        TextUtils.cleanSearchQuery(animeName));
    try {
      http.Response res;
      try {
        res = await _httpGet(
            Uri.parse('$_base/busca?busca=$q&page=1'),
            headers: _headers);
      } on TimeoutException {
        res = await _httpGet(
            Uri.parse('$_base/busca?busca=$q&page=1'),
            headers: _headers);
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
      for (final item in doc.querySelectorAll('div.ultimosAnimesHomeItem')) {
        final a = item.querySelector('a[href]');
        final href = _absolute(a?.attributes['href']);
        // Só páginas de série; ignora widgets/links de episódio.
        if (href.isEmpty ||
            !(href.contains('/animes/') || href.contains('/anime-dublado/'))) {
          continue;
        }
        if (!seen.add(href)) continue;
        final name = TextUtils.cleanTitle(
          item
                  .querySelector('.ultimosAnimesHomeItemInfosNome')
                  ?.text
                  .trim() ??
              a?.text.trim() ??
              href.split('/').where((s) => s.isNotEmpty).last,
        );
        if (name.isEmpty) continue;
        list.add(Anime(
          name: name,
          url: href,
          source: source,
          fallbackImageUrl:
              item.querySelector('.ultimosAnimesHomeItemImg img')?.attributes['src'],
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
      debugPrint('[DattebayoBR] Search error: $e');
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
      final episodes = <String, Episode>{};
      final base = anime.url.split('?').first.replaceFirst(RegExp(r'/+$'), '');
      // A lista é paginada (`/page/N`) e cada página repete itens: dedupe por
      // href. Limite de 20 páginas evita loop se o site devolver a última
      // página para N+1.
      for (var page = 1; page <= 20; page++) {
        final url = page == 1 ? base : '$base/page/$page';
        final res = await _httpGet(Uri.parse(url), headers: _headers);
        if (res.statusCode != 200) break;
        final doc = html_parser.parse(res.body);
        final items = doc.querySelectorAll('div.ultimosEpisodiosHomeItem');
        if (items.isEmpty) break;
        var added = 0;
        for (final item in items) {
          final href = _absolute(item.querySelector('a[href]')?.attributes['href']);
          if (href.isEmpty || !href.contains('/videos/')) continue;
          if (episodes.containsKey(href)) continue;
          final label =
              item.querySelector('.ultimosEpisodiosHomeItemInfosNum')?.text.trim() ??
                  item.querySelector('.ultimosEpisodiosHomeItemInfosNome')?.text.trim() ??
                  '';
          final number = _episodeNumber(label);
          if (number == null) continue;
          episodes[href] = Episode(
            number: '$number',
            url: href,
            title: item
                .querySelector('.ultimosEpisodiosHomeItemInfosNome')
                ?.text
                .trim(),
            thumbnail: item.querySelector('img')?.attributes['src'],
            owner: anime,
            source: source,
          );
          added++;
        }
        if (added == 0) break;
        // Só continua paginando quando o HTML aponta para a próxima página:
        // a maioria das séries cabe numa página só e o fetch extra (≈1 s no
        // Fire Stick) comia metade do orçamento de 8 s do provider.
        final next = '/page/${page + 1}';
        if (!res.body.contains(next)) break;
      }
      if (episodes.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes found in HTML',
          source: source,
        ));
      }
      final list = episodes.values.toList()
        ..sort((a, b) => (int.tryParse(a.number) ?? 0)
            .compareTo(int.tryParse(b.number) ?? 0));
      return ScraperResult.success(list);
    } catch (e) {
      debugPrint('[DattebayoBR] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// "Episódio 23" → 23; "… ep 23" → 23; "23" → 23. Nunca pega o primeiro
  /// número do título ("Slime **4**th Season ep 23" tem de dar 23) nem os
  /// dígitos do href (`/videos/579650` é um ID opaco, nunca um episódio).
  static int? _episodeNumber(String label) {
    final ep = RegExp(r'epis[oó]dio\s*(\d+)', caseSensitive: false)
            .firstMatch(label) ??
        RegExp(r'\bep\s*(\d+)', caseSensitive: false).firstMatch(label);
    if (ep != null) return int.tryParse(ep.group(1)!);
    final only = double.tryParse(label.trim());
    if (only != null) return only.toInt();
    return null;
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final res = await _httpGet(Uri.parse(episode.url), headers: {
        ..._headers,
        'Referer': '$_base/',
      });
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final audio = _audioTag(anime, episode);
      // `aba-type` → rótulo do servidor (SD/HD/FULLHD).
      final labels = <String, String>{};
      for (final aba in doc.querySelectorAll('div.Aba')) {
        final type = aba.attributes['aba-type']?.trim();
        final label = aba.text.trim();
        if (type != null && type.isNotEmpty && label.isNotEmpty) {
          labels[type] = label;
        }
      }
      // Assinatura + probe em paralelo: 3 servidores em série (SD/HD/FULLHD)
      // custavam ~4 s e encostavam no orçamento de 8 s do provider.
      final seen = <String>{};
      final pending = <Future<VideoSource?>>[];
      for (final container in doc.querySelectorAll('div.playerContainer')) {
        final type = container.attributes['id']?.trim() ?? '';
        final script = container.querySelector('script')?.text ?? '';
        final m = RegExp(r"""var\s+vid\s*=\s*['"]([^'"]+)['"]""")
            .firstMatch(script);
        final raw = m?.group(1)?.trim() ?? '';
        if (raw.isEmpty || !seen.add(raw)) continue;
        pending.add(() async {
          final signed = await _sign(raw, episode.url);
          if (signed == null) return null;
          final size = await probeMediaUrl(Uri.parse(signed),
              client: _client,
              headers: {'User-Agent': _ua, 'Referer': episode.url});
          if (size < 0) {
            debugPrint('[DattebayoBR] CDN probe failed for ${labels[type]}');
            return null;
          }
          return VideoSource(
            url: signed,
            quality: labels[type] ?? 'Auto',
            headers: {'User-Agent': _ua, 'Referer': episode.url},
            audio: audio,
          );
        }());
      }
      final sources =
          (await Future.wait(pending)).whereType<VideoSource>().toList();
      if (sources.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No playable stream (signature/probe failed)',
          source: source,
        ));
      }
      return ScraperResult.success(sources);
    } catch (e) {
      debugPrint('[DattebayoBR] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Assina o mp4 do R2 em `ads.animeyabu.net` (mesmo fluxo do site): devolve
  /// `vid + publicidade` (query presigned AWS), ou null quando o anunciante
  /// não responde com a assinatura.
  Future<String?> _sign(String vid, String referer) async {
    try {
      final uri = Uri.parse(
          '$_ads?url=${Uri.encodeComponent(vid)}');
      final res = await _httpGet(uri, headers: {
        'User-Agent': _ua,
        'Accept': '*/*',
        'Referer': referer,
        'Origin': _base,
      });
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! List || decoded.isEmpty) return null;
      final first = decoded.first;
      if (first is! Map) return null;
      final sig = first['publicidade']?.toString() ?? '';
      if (sig.isEmpty) return null;
      return '$vid$sig';
    } catch (e) {
      debugPrint('[DattebayoBR] sign error: $e');
      return null;
    }
  }

  String _audioTag(Anime? anime, Episode episode) {
    final url = '${anime?.url ?? ''} ${episode.url}'.toLowerCase();
    return url.contains('dublado') ? 'dublado' : 'legendado';
  }

  String _absolute(String? href) {
    final h = href?.trim() ?? '';
    if (h.isEmpty) return '';
    if (h.startsWith('http')) return h;
    if (h.startsWith('/')) return '$_base$h';
    return '$_base/$h';
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
            report.episodeCount = animes.first.episodes ?? 0;
          }
        case Failure(error: final err):
          if (err is EmptyResultError) {
            report.status = AvailabilityStatus.notFound;
            report.reason = 'Anime not found in catalog';
          } else if (err is UnknownError) {
            report.status = AvailabilityStatus.error;
            report.reason = 'Unknown error: ${err.message}';
          } else if (err is TimeoutError) {
            report.status = AvailabilityStatus.timeout;
            report.reason = 'Request timed out';
          }
        case Loading():
          break;
      }
    } on Exception catch (e) {
      report.status = AvailabilityStatus.exception;
      report.reason = 'Exception: $e';
    }
    return report;
  }

  /// Exposto só para testes: parse do bloco `var vid` de uma página.
  @visibleForTesting
  static Map<String, String> videoVars(Document doc) {
    final out = <String, String>{};
    for (final container in doc.querySelectorAll('div.playerContainer')) {
      final id = container.attributes['id']?.trim() ?? '';
      final script = container.querySelector('script')?.text ?? '';
      final m = RegExp(r"""var\s+vid\s*=\s*['"]([^'"]+)['"]""")
          .firstMatch(script);
      if (id.isNotEmpty && m != null) out[id] = m.group(1)!;
    }
    return out;
  }
}
