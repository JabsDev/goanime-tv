import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../constants/app_constants.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// AnimeFire provider, backed by the site's public JSON API
/// (`https://api.animefire.io`).
///
/// The legacy HTML scraping died with the 2026 site rebuild (Angular SPA:
/// old `/pesquisar/<slug>` route is 404, episode cards carry no `<a href>`,
/// the `/video/` endpoint no longer exists). Playback goes through
/// `GET /episode/{id}`, whose `streams[].url` is a DASH manifest
/// (served as `.jpg` from `akumast.net`, `content-type: application/dash+xml`
/// — mpv handles it).
///
/// API surface used (no auth, verified live 09/09/2026):
///  - `GET /animes/pesquisar?q=` → `{data:[{id,title,audio,poster_src,...}]}`
///  - `GET /anime/{animeId}`     → `{data:{episodes:[{id,number,title,...}]}}`
///  - `GET /episode/{episodeId}` → `{data:{streams:[{audio,url,qualities}]}}`
class AnimeFireAdapter extends AnimeSourceAdapter {
  static const _apiBase = 'https://api.animefire.io';
  static const _siteBase = 'https://animefire.io';

  final http.Client? _client;

  AnimeFireAdapter({http.Client? client}) : _client = client;

  /// Dispatches to [http.Client.get] when a mock client is injected, otherwise
  /// falls back to the app's global [apiClient] singleton. Real requests are
  /// serialized (min 250ms gap) — the API sits behind Cloudflare rate limits.
  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) {
      return _client.get(uri, headers: headers);
    }
    await _throttle();
    return apiClient.get(uri, headers: headers);
  }

  // ponytail: global last-request timestamp — good enough for serialization;
  // switch to per-endpoint queues if throughput ever matters.
  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _throttle() async {
    final now = DateTime.now();
    final since = now.difference(_lastRequest).inMilliseconds;
    const minGap = 250;
    if (since < minGap) {
      await Future.delayed(Duration(milliseconds: minGap - since));
    }
    _lastRequest = DateTime.now();
  }

  static const _headers = {
    'User-Agent': AppConstants.userAgent,
    'Accept': 'application/json',
    'Referer': '$_siteBase/',
  };

  @override
  AnimeSource get source => AnimeSource.animeFire;

  @override
  bool get implemented => true;

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final q = Uri.encodeQueryComponent(
        TextUtils.cleanSearchQuery(animeName));
    try {
      http.Response res;
      try {
        res = await _httpGet(Uri.parse('$_apiBase/animes/pesquisar?q=$q'),
            headers: _headers);
      } on TimeoutException {
        debugPrint('[AnimeFire] Search timeout, retrying once...');
        res = await _httpGet(Uri.parse('$_apiBase/animes/pesquisar?q=$q'),
            headers: _headers);
      }

      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final data = _dataList(res.body);
      if (data == null) {
        return ScraperResult.failure(ParseFailureError(
          message: 'Unexpected search payload',
          source: source,
        ));
      }
      final list = <Anime>[];
      for (final item in data) {
        if (item is! Map) continue;
        final id = item['id']?.toString() ?? '';
        final title = TextUtils.cleanTitle(
            item['title']?.toString().trim() ?? '');
        if (id.isEmpty || title.isEmpty) continue;
        list.add(Anime(
          name: title,
          url: '$_siteBase/anime/$id',
          source: AnimeSource.animeFire,
          fallbackImageUrl: item['poster_src']?.toString(),
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
        message: 'Search timed out after retry',
        source: source,
      ));
    } on FormatException {
      return ScraperResult.failure(ParseFailureError(
        message: 'JSON parse failure',
        source: source,
      ));
    } catch (e) {
      debugPrint('[AnimeFire] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Unexpected error: $e',
        source: source,
      ));
    }
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    try {
      final id = _animeId(anime.url);
      if (id == null) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No AnimeFire id in URL: ${anime.url}',
          source: source,
        ));
      }
      final res = await _httpGet(Uri.parse('$_apiBase/anime/$id'),
          headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final data = _dataMap(res.body);
      final raw = data?['episodes'];
      if (raw is! List) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes in payload',
          source: source,
        ));
      }
      final episodes = <Episode>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final epId = item['id']?.toString() ?? '';
        final rawNum = item['number'];
        final n = (rawNum is num)
            ? rawNum.toInt()
            : int.tryParse(rawNum?.toString() ?? '');
        if (epId.isEmpty || n == null) continue;
        episodes.add(Episode(
          number: '$n',
          url: '$_apiBase/episode/$epId',
          title: item['title']?.toString(),
          thumbnail: item['still_src']?.toString(),
          description: item['synopsis']?.toString(),
          owner: anime,
        ));
      }
      if (episodes.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed',
          source: source,
        ));
      }
      // Número real da API em vez de posição no array — defesa contra
      // payloads fora de ordem.
      episodes.sort((a, b) =>
          (int.tryParse(a.number) ?? 0).compareTo(int.tryParse(b.number) ?? 0));
      return ScraperResult.success(episodes);
    } catch (e, stackTrace) {
      debugPrint('[AnimeFireAdapter] getEpisodes ERROR: $e\n$stackTrace');
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
      final epId = _lastSegment(episode.url);
      if (epId == null) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episode id in URL: ${episode.url}',
          source: source,
        ));
      }
      final res = await _httpGet(Uri.parse('$_apiBase/episode/$epId'),
          headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final data = _dataMap(res.body);
      final raw = data?['streams'];
      if (raw is! List) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No streams in payload',
          source: source,
        ));
      }
      final sources = <VideoSource>[];
      final seen = <String>{};
      for (final item in raw) {
        if (item is! Map) continue;
        final url = item['url']?.toString() ?? '';
        if (url.isEmpty || !seen.add(url)) continue;
        final qualities = (item['qualities'] is List)
            ? (item['qualities'] as List).map((q) => q.toString()).toList()
            : const <String>[];
        // Rótulo numérico ("480p") para o quality picker pontuar; áudio
        // (dublado/legendado) vai junto quando há mais de um stream.
        var quality = qualities.isNotEmpty ? qualities.join('/') : 'Auto';
        final audio = item['audio']?.toString() ?? '';
        if (raw.length > 1 && audio.isNotEmpty) quality = '$quality · $audio';
        sources.add(VideoSource(
          url: url,
          quality: quality,
          headers: {
            'User-Agent': AppConstants.userAgent,
            'Referer': '$_siteBase/',
          },
        ));
      }
      if (sources.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No video sources found',
          source: source,
        ));
      }
      return ScraperResult.success(sources);
    } catch (e) {
      debugPrint('[AnimeFire] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    final report = AvailabilityReport(
      source: source,
      animeName: animeName,
    );

    try {
      final result = await search(animeName);
      switch (result) {
        case Success(data: final animes):
          if (animes.isNotEmpty) {
            report.status = AvailabilityStatus.available;
            report.episodeCount = animes.first.episodes ?? 0;
            return report;
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

  /// Opaque anime id from a site URL (`/anime/<id>`). Legacy
  /// `/animes/<slug>-todos-os-episodios` URLs carry no id — they resolve to
  /// null so the caller can drop the stale persisted match and re-discover.
  String? _animeId(String url) {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    if (!uri.pathSegments.contains('anime')) return null;
    final id = uri.pathSegments.last;
    // IDs opacos do site novo; slugs legados nunca são id válido.
    if (id.isEmpty || id.contains('todos-os-episodios')) return null;
    return id;
  }

  String? _lastSegment(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final seg = uri.pathSegments.last;
    return seg.isEmpty ? null : seg;
  }

  /// Top-level `data` as List (search payload). Null on any shape mismatch.
  List? _dataList(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['data'] is List) {
        return decoded['data'] as List;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Top-level `data` as Map (anime/episode payloads). Null on mismatch.
  Map<String, dynamic>? _dataMap(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['data'] is Map) {
        return (decoded['data'] as Map)
            .map((k, v) => MapEntry(k.toString(), v));
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
