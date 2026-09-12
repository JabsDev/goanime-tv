import 'dart:async' show TimeoutException;
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// Anime Player provider (PT-BR): DooPlay-based WordPress site. Video is
/// reached via a traffic-protected CDN: the episode page embeds `.mp4`-keyed
/// URLs (`thatwebsite.com.br/jax_r2/?key=...`) that resolve to a signed
/// media URL served in the page body after a redirect. We re-fetch the
/// traffic URL with a browser UA and pull the signed `infra-*.thatwebsite...`
/// URL out of the returned HTML.
class AnimePlayerAdapter extends AnimeSourceAdapter {
  final http.Client? _client;

  AnimePlayerAdapter({http.Client? client}) : _client = client;

  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) {
      return _client.get(uri, headers: headers);
    }
    return apiClient.get(uri, headers: headers);
  }

  static const _base = 'https://animeplayer.com.br';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  @override
  AnimeSource get source => AnimeSource.animePlayer;
  @override
  bool get implemented => true;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    final url = Uri.parse('$_base/?s=${Uri.encodeQueryComponent(query)}');
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
      for (final item in doc.querySelectorAll('.result-item article')) {
        final a = item.querySelector('.image a') ?? item.querySelector('a');
        final href = a?.attributes['href'] ?? '';
        if (href.isEmpty || !href.contains('/animes/')) continue;
        final img = item.querySelector('img');
        final name = TextUtils.cleanTitle(
          img?.attributes['alt'] ?? a?.text.trim() ?? href.split('/').last,
        );
        if (name.isEmpty) continue;
        list.add(Anime(
          name: name,
          url: href,
          source: source,
          fallbackImageUrl: img?.attributes['src'],
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
      debugPrint('[AnimePlayer] Search error: $e');
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
      final hrefs = <String>{};
      for (final a in doc.querySelectorAll('a')) {
        final href = a.attributes['href'] ?? '';
        if (href.contains('/episodios/') && !href.endsWith('/episodios/')) {
          hrefs.add(href);
        }
      }
      if (hrefs.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episode URLs found in HTML',
          source: source,
        ));
      }
      final list = hrefs.toList()..sort(_compareEpisodeUrls);
      final episodes = list.map((url) {
        final sn = seasonEpisode(url);
        return Episode(
          number: (sn.$2 ?? 0).toString(),
          url: url,
          source: source,
          owner: anime,
          season: sn.$1,
        );
      }).toList();
      return ScraperResult.success(episodes);
    } catch (e) {
      debugPrint('[AnimePlayer] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Total comparator for episode URLs: (season nulls-last, number,
  /// url-tiebreak). `null` season sorts LAST (unknown ≠ S1); never returns 0
  /// for distinct URLs (deterministic order on combined pages).
  static int _compareEpisodeUrls(String a, String b) {
    final sa = seasonEpisode(a);
    final sb = seasonEpisode(b);
    if (sa.$1 == null && sb.$1 != null) return 1;
    if (sa.$1 != null && sb.$1 == null) return -1;
    if (sa.$1 != null && sb.$1 != null && sa.$1 != sb.$1) {
      return sa.$1!.compareTo(sb.$1!);
    }
    if (sa.$2 != sb.$2) return (sa.$2 ?? 0).compareTo(sb.$2 ?? 0);
    return a.compareTo(b);
  }

  /// (season, number) from the URL slug: `-SxE` (`…-ken-4-episodio-21` no —
  /// this site uses `naruto-1x1` → (1,1)) with legacy `-episodio-N` fallback
  /// → (null, N). Same contract as the DooPlay helper (duplicated ~15 lines
  /// on purpose — 2 slug formats, no shared abstraction until 3+ converge).
  @visibleForTesting
  static (int?, int?) seasonEpisode(String url) {
    var path = url.split('?').first.split('#').first;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final lower = path.toLowerCase();
    if (RegExp(r'-(\d+)-(\d+)-episodio-(\d+)$').firstMatch(lower)
        case final m?) {
      // ponytail: specials x.5 out of int-season resolve by design.
      debugPrint('[SeasonResolve] AnimePlayer special x.5 (season=null): $url');
      return (null, int.tryParse(m.group(3)!));
    }
    if (RegExp(r'-(\d{1,2})-episodio-(\d+)(?:-parte-\d+)?$').firstMatch(lower)
        case final m?) {
      return (int.tryParse(m.group(1)!), int.tryParse(m.group(2)!));
    }
    var m = RegExp(r'-(\d{1,2})x(\d{1,4})$').firstMatch(lower);
    if (m != null) {
      return (int.tryParse(m.group(1)!), int.tryParse(m.group(2)!));
    }
    m = RegExp(r'episodio[\s-]*(\d+)', caseSensitive: false).firstMatch(path);
    if (m != null) return (null, int.tryParse(m.group(1)!));
    return (null, null);
  }

  /// Episode number from the URL slug. Current scheme is `-SxE`
  /// (`naruto-1x1` → 1); the legacy `-episodio-N` form is kept as fallback.
  /// Legacy wrapper (number only); prefer [seasonEpisode] for season-aware
  /// resolution.
  @visibleForTesting
  int? episodeNumber(String url) => seasonEpisode(url).$2;

  /// Season-aware resolve (same rule as DooPlay): hinted season present →
  /// match by number-IN-season; hinted but page COMBINED without that
  /// episode → [] (never silently S1); otherwise absolute fallback + log.
  @override
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber,
      {Anime? catalog}) async {
    final eps = await getEpisodes(match);
    Episode? target;
    switch (eps) {
      case Success(:final data):
        final hint =
            catalog == null ? null : TextUtils.seasonOf(catalog.name);
        if (hint != null) {
          final inSeason = data
              .where((e) => e.season == hint)
              .toList()
            ..sort((a, b) =>
                (int.tryParse(a.number) ?? 0)
                    .compareTo(int.tryParse(b.number) ?? 0));
          for (final e in inSeason) {
            if (int.tryParse(e.number) == episodeNumber) {
              target = e;
              break;
            }
          }
          if (target == null) {
            final seasons =
                data.map((e) => e.season).whereType<int>().toSet();
            if (seasons.length >= 2) return const [];
            debugPrint('[SeasonResolve] AnimePlayer fallback absoluto '
                'ep=$episodeNumber hint=$hint url=${match.url}');
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
      final sources = await _extractFromAnimePlayer(episode.url);
      if (sources.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No video sources found',
          source: source,
        ));
      }
      return ScraperResult.success(sources);
    } catch (e) {
      debugPrint('[AnimePlayer] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  Future<List<VideoSource>> _extractFromAnimePlayer(String episodeUrl) async {
    final res = await _httpGet(Uri.parse(episodeUrl), headers: {
      'User-Agent': _ua,
      'Referer': '$_base/',
    });
    if (res.statusCode != 200) return [];

    // Episodes embed one or more CDN-keyed URLs.
    final keys = RegExp(
      r'''https://[^"'\s<>]+thatwebsite[^"'\s<>]*jax[^"'\s<>]*(?:key=[^"'\s<>]+)''',
    ).allMatches(res.body).map((m) => m.group(0)!).toList();
    // Also a raw .mp4 in a [data-label] / video source.
    final mp4 = RegExp(
      r'''https?://[^"'\s<>]+\.mp4''',
    ).firstMatch(res.body);

    final results = <VideoSource>[];
    final seen = <String>{};
    void add(String url, String quality) {
      if (url.isEmpty || !seen.add(url)) return;
      results.add(VideoSource(
        url: url,
        quality: quality,
        headers: {'User-Agent': _ua, 'Referer': '$_base/'},
      ));
    }

    for (final key in keys) {
      final signed = await _resolveTraffic(key);
      if (signed != null) add(signed, 'Auto');
    }
    if (results.isNotEmpty) return results;

    if (mp4 != null && mp4.group(0)!.contains('thatwebsite')) {
      final signed = await _resolveTraffic(mp4.group(0)!);
      if (signed != null) add(signed, 'Auto');
    } else if (mp4 != null) {
      add(mp4.group(0)!, 'Auto');
    }
    return results;
  }

  /// Fetches the traffic CDN URL and extracts the signed media URL embedded in
  /// its HTML. Returns null if the media URL cannot be extracted.
  Future<String?> _resolveTraffic(String url) async {
    try {
      final res = await _httpGet(Uri.parse(url), headers: {
        'User-Agent': _ua,
        'Referer': '$_base/',
      });
      if (res.statusCode != 200) return null;
      final signed = RegExp(
        r'''https://infra[-a-z0-9]+\.thatwebsite\.com\.br/[^"'\s<>\\]+''',
      ).firstMatch(res.body);
      return signed?.group(0);
    } catch (e) {
      debugPrint('[AnimePlayer] Traffic resolve error: $e');
      return null;
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
}