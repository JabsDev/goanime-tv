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
///  - `GET /anime/{animeId}`     → `{data:{seasons:[{number,first_episode_number}],
///    episodes:[{id,season,number,title,...}]}}` — episodes are numbered
///    **per season**; the absolute number is
///    `first_episode_number(season) + number - 1`.
///  - `GET /episode/{episodeId}` → `{data:{streams:[{audio,url,qualities}]}}`
///    where each stream URL is a single DASH manifest carrying all of its
///    `qualities` as Representations — hence one `VideoSource` per quality
///    (+ `Auto` when several) sharing the manifest URL, disambiguated by
///    `dashHeight` and resolved through the local MPD proxy in the player.
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
      // Per-season numbering → absolute: `seasons[].first_episode_number`
      // gives the absolute offset of each season (verified live: Naruto
      // S1..S4 → 1/53/105/159; Demon Slayer → 1/27/45/56). Without it,
      // `resolveVideo` (match by absolute `number`) misses every episode
      // past the longest season and can match the wrong season silently.
      final seasonOffset = _seasonOffsets(data?['seasons']);
      final episodes = <Episode>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final epId = item['id']?.toString() ?? '';
        final rawNum = item['number'];
        final n = (rawNum is num)
            ? rawNum.toInt()
            : int.tryParse(rawNum?.toString() ?? '');
        if (epId.isEmpty || n == null) continue;
        final rawSeason = item['season'];
        final s = (rawSeason is num)
            ? rawSeason.toInt()
            : int.tryParse(rawSeason?.toString() ?? '');
        final abs = (s != null && seasonOffset.containsKey(s))
            ? seasonOffset[s]! + n - 1
            : n;
        episodes.add(Episode(
          number: '$abs',
          url: '$_apiBase/episode/$epId',
          title: item['title']?.toString(),
          thumbnail: item['still_src']?.toString(),
          description: item['synopsis']?.toString(),
          season: s,
          owner: anime,
        ));
      }
      if (episodes.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed',
          source: source,
        ));
      }
      // Absolute numbers — defense against out-of-order payloads (and, with
      // the mapping above, against per-season numbering).
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

  /// Season number from a catalog title. Delegates to [TextUtils.seasonOf]
  /// (neutral owner — DooPlay/bestMatch share it; never import this adapter
  /// from another provider). Null when the title carries no season — the
  /// catalog entry then covers the series from S1 (relative == absolute).
  static int? seasonFromCatalogName(String name) => TextUtils.seasonOf(name);

  /// Season-aware resolve: the catalog (AniList) splits seasons into separate
  /// entries ("... 4th Season", grid 1..21) while AnimeFire serves them on one
  /// combined page with absolute numbers (S4E21 == abs 93). Matching the raw
  /// [episodeNumber] would land on S1E21. When [catalog] names a season, the
  /// number is season-relative: take the episode with that IN-SEASON number
  /// (matched by number, never by position — a gap in the API must yield "not
  /// found", not a silent shift onto the next episode).
  /// Falls back to absolute matching (base behavior) when there's no season
  /// hint or the season isn't on the page; the fallback is logged (tagged)
  /// ONLY when a hint was present, so "EP futuro" is distinguishable from a
  /// wrong match in `adb logcat`. No AniList coupling here (`nextAiringEpisode`
  /// is enrichment, 403-prone) — future/not-found both stay `[]`.
  @override
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber,
      {Anime? catalog}) async {
    final eps = await getEpisodes(match);
    Episode? target;
    switch (eps) {
      case Success(:final data):
        final season =
            catalog == null ? null : seasonFromCatalogName(catalog.name);
        if (season != null) {
          final inSeason = data.where((e) => e.season == season).toList()
            ..sort((a, b) =>
                (int.tryParse(a.number) ?? 0)
                    .compareTo(int.tryParse(b.number) ?? 0));
          // In-season number = absolute − season start + 1 (contiguous
          // seasons: identical to the old positional pick; with a gap in the
          // API payload the missing EP honestly yields "not found" instead of
          // shifting every later EP onto its neighbour).
          final start = inSeason.isEmpty
              ? null
              : int.tryParse(inSeason.first.number);
          if (start != null) {
            for (final e in inSeason) {
              final abs = int.tryParse(e.number);
              if (abs != null && abs - start + 1 == episodeNumber) {
                target = e;
                break;
              }
            }
          }
          if (target == null) {
            final name = catalog?.name ?? '';
            debugPrint('[SeasonResolve] AnimeFire fallback absoluto '
                'ep=$episodeNumber season=$season '
                'catalog=${name.length > 40 ? '${name.substring(0, 40)}…' : name}');
            // Hinted season on a COMBINED page (≥2 seasons) with no in-season
            // hit: never fall back to the absolute number (that IS the
            // S4E21→S1E21 bug) — the episode is missing/future here.
            final seasons = data.map((e) => e.season).whereType<int>().toSet();
            if (seasons.length >= 2) return const [];
          }
        }
        target ??= () {
          for (final e in data) {
            if (int.tryParse(e.number) == episodeNumber) return e;
          }
          return null;
        }();
      case Failure():
      case Loading():
        return const [];
    }
    if (target == null) return const [];

    final vs = await getVideoSources(target, anime: match);
    switch (vs) {
      case Success(:final data):
        return data;
      case Failure():
      case Loading():
        return const [];
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
      var skippedOffline = 0;
      for (final item in raw) {
        if (item is! Map) continue;
        final url = item['url']?.toString() ?? '';
        final audio = item['audio']?.toString() ?? '';
        if (url.isEmpty) {
          skippedOffline++;
          continue;
        }
        // ponytail: dedup por (url, áudio) — por URL pura colapsaria áudios
        // se um dia compartilharem o manifesto.
        final streamKey = '${url.toLowerCase()}|${audio.toLowerCase()}';
        if (!seen.add(streamKey)) continue;
        // Um manifesto DASH carrega todas as `qualities`: uma entrada por
        // qualidade (mesma URL, `dashHeight` distinto) + `Auto` (adaptativo)
        // quando há mais de uma. Com qualidade única, só a fixa — `Auto`
        // seria um botão redundante para o mesmo conteúdo.
        final qualities = (item['qualities'] is List)
            ? (item['qualities'] as List)
                .map((q) => q.toString())
                .map((q) => q.trim())
                .where((q) => q.isNotEmpty)
                .toSet()
                .toList()
            : const <String>[];
        // Áudio vira dimensão própria (o diálogo mostra o card
        // Dublado/Legendado antes das resoluções); o rótulo carrega só a
        // resolução. Mantém mesmo com stream único para o passo de áudio
        // aparecer também quando só há um áudio disponível.
        final track = audio.isNotEmpty ? audio : null;
        void add(String label, int? dashHeight) {
          final key = '$url|$dashHeight|$audio';
          if (!seen.add(key)) return;
          sources.add(VideoSource(
            url: url,
            quality: label,
            headers: {
              'User-Agent': AppConstants.userAgent,
              'Referer': '$_siteBase/',
            },
            dashHeight: dashHeight,
            audio: track,
          ));
        }

        if (qualities.length > 1) add('Auto', null);
        var fixed = 0;
        for (final q in qualities) {
          final h = RegExp(r'(\d{3,4})').firstMatch(q);
          final height = h == null ? null : int.tryParse(h.group(1)!);
          if (height == null) continue;
          add(q, height);
          fixed++;
        }
        // Rótulo cru sem número (ex.: "HD") ou lista vazia: Auto honesto.
        if (fixed == 0) add('Auto', null);
      }
      if (skippedOffline > 0) {
        debugPrint('[AnimeFire] Skipped $skippedOffline offline stream(s) '
            'for $epId (only dubbed/subbed available)');
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

  /// Maps season number → absolute first-episode number from the
  /// `seasons` array (`[{number, first_episode_number}]`). Empty when the
  /// payload carries no seasons — callers then fall back to raw numbers.
  Map<int, int> _seasonOffsets(Object? seasons) {
    final offsets = <int, int>{};
    if (seasons is! List) return offsets;
    for (final item in seasons) {
      if (item is! Map) continue;
      final rawS = item['number'];
      final rawFirst = item['first_episode_number'];
      final s = (rawS is num)
          ? rawS.toInt()
          : int.tryParse(rawS?.toString() ?? '');
      final first = (rawFirst is num)
          ? rawFirst.toInt()
          : int.tryParse(rawFirst?.toString() ?? '');
      if (s == null || first == null) continue;
      offsets[s] = first;
    }
    return offsets;
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
