import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../constants/app_constants.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import 'anime_source_adapter.dart';

/// Goyabu provider (PT-BR): WordPress-based site. Search via the WP REST API
/// (with an HTML fallback), episode listing from the `allEpisodes` JS array,
/// and stream resolution via the Blogger decode AJAX endpoint (which returns
/// multiple qualities) with iframe/direct fallbacks.
class GoyabuAdapter implements AnimeSourceAdapter {
  GoyabuAdapter();

  static final RegExp _nonceRe = RegExp(r'"nonce"\s*:\s*"([a-f0-9]+)"');
  static final List<RegExp> _episodePatterns = [
    RegExp(r'(?:const|let|var)\s+allEpisodes\s*=\s*(\[[\s\S]*?\])\s*;'),
    RegExp(r'episodes\s*[:=]\s*(\[[\s\S]*?\])'),
    RegExp(r'"episodes"\s*:\s*(\[[\s\S]*?\])'),
    RegExp(r'episodeList\s*[:=]\s*(\[[\s\S]*?\])'),
  ];
  static final RegExp _unquotedKeyRe = RegExp(r'([,{\[\s]|^)(\w+)\s*:');
  static final RegExp _playersDataRe =
      RegExp(r'var\s+playersData\s*=\s*(\[.*?\])\s*;', dotAll: true);
  static final List<RegExp> _bloggerPatterns = [
    RegExp(r'''blogger_token\s*[:=]\s*["']([^"']+)["']'''),
    RegExp(r'''data-blogger-token\s*=\s*["']([^"']+)["']'''),
    RegExp(r'"blogger_token"\s*:\s*"([^"]+)"'),
  ];
  static final List<RegExp> _videoPatterns = [
    RegExp(r'"file"\s*:\s*"(https?://[^"]+\.m3u8[^"]*)"'),
    RegExp(r'"file"\s*:\s*"(https?://[^"]+\.mp4[^"]*)"'),
    RegExp(r'''src\s*[:=]\s*["'](https?://[^"']+\.m3u8[^"']*)'''),
    RegExp(r'''src\s*[:=]\s*["'](https?://[^"']+\.mp4[^"']*)'''),
  ];

  @override
  AnimeSource get source => AnimeSource.goyabu;

  Map<String, String> get _headers => {
        'User-Agent': AppConstants.userAgent,
        'Accept-Language': 'pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7',
        'Referer': '${AppConstants.goyabuBase}/',
      };

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final query = animeName
        .trim()
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    final stopwatch = Stopwatch()..start();
    try {
      final nonce = await _fetchNonce();
      if (nonce != null) {
        final apiResults = await _searchApi(query, nonce);
        if (apiResults.isNotEmpty) return ScraperResult.success(apiResults);
      }
      final htmlResults = await _searchHtml(query);
      if (htmlResults.isNotEmpty) return ScraperResult.success(htmlResults);
      return ScraperResult.failure(EmptyResultError(
        message: 'No results found',
        source: source,
        operationDuration: stopwatch.elapsed,
      ));
    } catch (e) {
      debugPrint('[Goyabu] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Search error: $e',
        source: source,
        operationDuration: stopwatch.elapsed,
        originalError: e,
      ));
    }
  }

  Future<String?> _fetchNonce() async {
    try {
      final res = await apiClient.get(
        Uri.parse(AppConstants.goyabuBase),
        headers: _headers,
      );
      if (res.statusCode != 200) return null;
      return _nonceRe.firstMatch(res.body)?.group(1);
    } catch (e) {
      debugPrint('[Goyabu] Nonce error: $e');
      return null;
    }
  }

  Future<List<Anime>> _searchApi(String query, String nonce) async {
    final url = '${AppConstants.goyabuBase}/wp-json/animeonline/search/'
        '?keyword=${Uri.encodeQueryComponent(query)}&nonce=$nonce';
    final res = await apiClient.get(
      Uri.parse(url),
      headers: {..._headers, 'Accept': 'application/json'},
    );
    if (res.statusCode != 200) return [];
    if (res.body.trimLeft().startsWith('<')) return [];

    final list = <Anime>[];
    try {
      final map = jsonDecode(res.body);
      if (map is Map) {
        for (final raw in map.values) {
          if (raw is! Map) continue;
          final title = raw['title']?.toString() ?? '';
          final url = raw['url']?.toString() ?? '';
          if (title.isEmpty || url.isEmpty) continue;
          final img = raw['img']?.toString();
          final resolved = _resolveUrl(url);
          list.add(Anime(
            name: title,
            url: resolved,
            source: AnimeSource.goyabu,
            goyabuUrl: resolved,
            fallbackImageUrl: img,
          ));
        }
      }
    } catch (_) {}
    return list;
  }

  Future<List<Anime>> _searchHtml(String query) async {
    final url =
        '${AppConstants.goyabuBase}/?s=${Uri.encodeQueryComponent(query)}';
    final res = await apiClient.get(Uri.parse(url), headers: _headers);
    if (res.statusCode != 200) return [];
    final doc = html_parser.parse(res.body);
    final list = <Anime>[];
    final seen = <String>{};
    for (final s in doc.querySelectorAll('article a, .anime-item a, .post a')) {
      final href = s.attributes['href'] ?? '';
      if (href.isEmpty || !href.contains('/anime/')) continue;
      var title = s.querySelector('h3')?.text.trim() ??
          s.querySelector('h2')?.text.trim() ??
          s.querySelector('img')?.attributes['alt']?.trim() ??
          '';
      if (title.isEmpty) continue;
      final img = s.querySelector('img')?.attributes['src'] ??
          s.querySelector('img')?.attributes['data-src'];
      final resolved = _resolveUrl(href);
      if (!seen.add(resolved)) continue;
      list.add(Anime(
        name: title,
        url: resolved,
        source: AnimeSource.goyabu,
        goyabuUrl: resolved,
        fallbackImageUrl: img,
      ));
    }
    return list;
  }

  @override
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
    final url = anime.goyabuUrl ?? anime.url;
    if (url.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Empty URL',
        source: source,
        operationDuration: Duration.zero,
      ));
    }
    final stopwatch = Stopwatch()..start();
    try {
      // HTTP call with timeout retry (D-04)
      http.Response res;
      try {
        res = await apiClient.get(Uri.parse(url), headers: _headers);
      } on TimeoutException {
        debugPrint('[Goyabu] Episodes timeout, retrying once...');
        res = await apiClient.get(Uri.parse(url), headers: _headers);
      }

      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }
      final episodes = _parseEpisodesFromJs(res.body);
      if (episodes.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }
      episodes.sort((a, b) {
        final na = int.tryParse(RegExp(r'\d+').firstMatch(a.number)?.group(0) ?? '0') ?? double.infinity.toInt();
        final nb = int.tryParse(RegExp(r'\d+').firstMatch(b.number)?.group(0) ?? '0') ?? double.infinity.toInt();
        return na.compareTo(nb);
      });
      return ScraperResult.success(EpisodesResult(episodes, {}));
    } on TimeoutException {
      return ScraperResult.failure(TimeoutError(
        message: 'Episodes timed out after retry',
        source: source,
        operationDuration: stopwatch.elapsed,
        timeoutValue: AppConstants.requestTimeout,
      ));
    } catch (e) {
      debugPrint('[Goyabu] Episodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Episodes error: $e',
        source: source,
        operationDuration: stopwatch.elapsed,
        originalError: e,
      ));
    }
  }

  List<Episode> _parseEpisodesFromJs(String html) {
    for (final re in _episodePatterns) {
      final m = re.firstMatch(html);
      if (m == null) continue;
      var jsonStr = m.group(1)!;
      List? data;
      try {
        data = jsonDecode(jsonStr) as List;
      } catch (_) {
        final cleaned = jsonStr
            .replaceAllMapped(_unquotedKeyRe, (mm) => '${mm[1]}"${mm[2]}":')
            .replaceAll("'", '"');
        try {
          data = jsonDecode(cleaned) as List;
        } catch (_) {
          continue;
        }
      }
      final episodes = <Episode>[];
      for (var i = 0; i < data.length; i++) {
        final ep = data[i] as Map;
        var num = i + 1;
        final epStr = ep['episodio']?.toString() ?? '';
        final parsed = int.tryParse(epStr);
        if (parsed != null) num = parsed;
        final id = ep['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        episodes.add(Episode(
          number: '$num',
          url: '${AppConstants.goyabuBase}/?p=$id',
          title: 'Episódio $num',
        ));
      }
      if (episodes.isNotEmpty) return episodes;
    }
    return [];
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final res = await apiClient.get(Uri.parse(episode.url), headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }
      final html = res.body;
      final doc = html_parser.parse(html);

      // Strategy 2 (primary): playersData blogger_token -> decode AJAX (returns
      // multiple qualities). Prioritized because it yields quality options.
      final playerData = _extractPlayerData(html);
      final token = playerData.$1;
      final bloggerUrl = playerData.$2;
      if (token.isNotEmpty) {
        final sources = await _decodeBloggerToken(token);
        if (sources.isNotEmpty) return ScraperResult.success(sources);
      }

      // Strategy 1: iframe / video element.
      final iframe = doc.querySelector('iframe')?.attributes['src'];
      if (iframe != null && iframe.startsWith('http')) {
        return ScraperResult.success([VideoSource(url: iframe, quality: 'Auto', headers: _headers)]);
      }
      final videoSrc = doc.querySelector('video source')?.attributes['src'] ??
          doc.querySelector('video[data-video-src]')?.attributes['data-video-src'];
      if (videoSrc != null && videoSrc.startsWith('http')) {
        return ScraperResult.success([VideoSource(url: videoSrc, quality: 'Auto', headers: _headers)]);
      }

      // Strategy 3: regex video URLs in scripts.
      for (final re in _videoPatterns) {
        final m = re.firstMatch(html);
        if (m != null) {
          return ScraperResult.success([
            VideoSource(url: m.group(1)!, quality: 'Auto', headers: _headers)
          ]);
        }
      }

      // Strategy 4: blogger embed URL as last resort.
      if (bloggerUrl.isNotEmpty && bloggerUrl.startsWith('http')) {
        return ScraperResult.success([VideoSource(url: bloggerUrl, quality: 'Auto', headers: _headers)]);
      }
      return ScraperResult.failure(EmptyResultError(
        message: 'No video sources found',
        source: source,
        operationDuration: stopwatch.elapsed,
      ));
    } catch (e) {
      debugPrint('[Goyabu] Video error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source error: $e',
        source: source,
        operationDuration: stopwatch.elapsed,
        originalError: e,
      ));
    }
  }

  (String, String) _extractPlayerData(String html) {
    var token = '';
    var bloggerUrl = '';
    final m = _playersDataRe.firstMatch(html);
    if (m != null) {
      try {
        final players = jsonDecode(m.group(1)!) as List;
        if (players.isNotEmpty) {
          final first = players.first as Map;
          token = first['blogger_token']?.toString() ?? '';
          bloggerUrl = first['url']?.toString() ?? '';
        }
      } catch (_) {}
    }
    if (token.isEmpty) {
      for (final re in _bloggerPatterns) {
        final bm = re.firstMatch(html);
        if (bm != null) {
          token = bm.group(1)!;
          break;
        }
      }
    }
    return (token, bloggerUrl);
  }

  Future<List<VideoSource>> _decodeBloggerToken(String token) async {
    try {
      final res = await apiClient.post(
        Uri.parse('${AppConstants.goyabuBase}/wp-admin/admin-ajax.php'),
        headers: {
          ..._headers,
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: 'action=decode_blogger_video&token=${Uri.encodeQueryComponent(token)}',
      );
      if (res.statusCode != 200) return [];
      final body = res.body;
      if (body.trimLeft().startsWith('<')) return [];

      dynamic result;
      try {
        result = jsonDecode(body);
      } catch (_) {
        final t = body.trim();
        if (t.startsWith('http')) {
          return [VideoSource(url: t, quality: 'Auto', headers: _headers)];
        }
        return [];
      }

      final data = result is Map ? result['data'] : null;
      final sources = <VideoSource>[];
      final seen = <String>{};

      if (data is Map && data['play'] is List) {
        final play = data['play'] as List;
        // Sort by size descending so highest quality is first.
        final items = play.whereType<Map>().toList()
          ..sort((a, b) {
            final sa = (a['size'] is num) ? (a['size'] as num).toInt() : 0;
            final sb = (b['size'] is num) ? (b['size'] as num).toInt() : 0;
            return sb.compareTo(sa);
          });
        for (final item in items) {
          final src = item['src']?.toString() ?? '';
          if (src.isEmpty || !src.startsWith('http') || !seen.add(src)) continue;
          final size = item['size'];
          final quality = size is num ? '${size.toInt()}p' : 'Auto';
          sources.add(VideoSource(url: src, quality: quality, headers: _headers));
        }
        if (sources.isNotEmpty) return sources;
      }

      // Fallback: single URL under common keys.
      for (final obj in [result, data]) {
        if (obj is! Map) continue;
        for (final key in ['url', 'file', 'src', 'video_url', 'stream_url']) {
          final val = obj[key];
          if (val is String && val.startsWith('http') && seen.add(val)) {
            sources.add(VideoSource(url: val, quality: 'Auto', headers: _headers));
          }
        }
      }
      return sources;
    } catch (e) {
      debugPrint('[Goyabu] Blogger decode error: $e');
      return [];
    }
  }

  String _resolveUrl(String ref) {
    if (ref.startsWith('http')) return ref;
    if (ref.startsWith('/')) return '${AppConstants.goyabuBase}$ref';
    return '${AppConstants.goyabuBase}/$ref';
  }
}
