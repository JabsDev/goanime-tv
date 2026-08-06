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
class AnimePlayerAdapter implements AnimeSourceAdapter {
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
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
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
      final list = hrefs.toList()
        ..sort((a, b) {
          final na = _episodeNumber(a);
          final nb = _episodeNumber(b);
          if (na == null || nb == null) return 0;
          return na.compareTo(nb);
        });
      final episodes = list.map((url) {
        return Episode(
          number: (_episodeNumber(url) ?? 0).toString(),
          url: url,
          source: source,
          owner: anime,
        );
      }).toList();
      return ScraperResult.success(EpisodesResult(
        episodes,
        {source.toString(): episodes},
      ));
    } catch (e) {
      debugPrint('[AnimePlayer] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  int? _episodeNumber(String url) {
    final m = RegExp(r'episodio[\s-]*(\d+)').firstMatch(url);
    return m == null ? null : int.tryParse(m.group(1)!);
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