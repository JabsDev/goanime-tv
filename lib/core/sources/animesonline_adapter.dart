import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';
import 'cdn_resolver.dart';
import 'dooplay_v2_extractor.dart';

/// AnimesOnline-cluster provider (PT-BR): `animesonline.cloud`, its clones
/// `animesdrive.online` and `animeq.blog` (same database, `wp_json` transport)
/// and `animeplay.cloud` (`admin_ajax` transport). Search and episode listing
/// are HTML scraping; video resolves through [DooPlayV2Extractor] (Layer A)
/// with the CDN probe fallback (Layer B) as last resort.
class AnimesOnlineAdapter extends AnimeSourceAdapter {
  final AnimeSource _source;
  final http.Client? _client;

  AnimesOnlineAdapter({
    required AnimeSource source,
    http.Client? client,
  })  : _source = source,
        _client = client;

  static const Map<AnimeSource, String> baseUrls = {
    AnimeSource.animesOnlineCloud: 'https://animesonline.cloud',
    AnimeSource.animesDrive: 'https://animesdrive.online',
    AnimeSource.animeQ: 'https://animeq.blog',
    AnimeSource.animePlay: 'https://animeplay.cloud',
  };

  String get baseUrl => baseUrls[_source] ?? 'https://animesonline.cloud';

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) return _client.get(uri, headers: headers);
    return apiClient.get(uri, headers: headers);
  }

  @override
  AnimeSource get source => _source;

  @override
  bool get implemented => true;

  @override
  Future<Anime?> resolveAnime(Anime animeRef) async {
    // Cluster catalogs index series by English (PT-BR) title; a romaji name
    // ("Ore dake Level Up na Ken") leaves bestMatch with no title signal, so
    // the site's own ordering wins and S2/spin-offs beat the main series.
    // Search the English title first, fall back to the given name.
    final queries = <String>{
      if (animeRef.englishName != null && animeRef.englishName!.isNotEmpty)
        animeRef.englishName!,
      animeRef.name,
    };
    for (final q in queries) {
      final result = await search(TextUtils.cleanSearchQuery(q));
      switch (result) {
        case Success(data: final candidates):
          final valid = candidates
              .where((a) => a.url.isNotEmpty && _overlaps(q, a.name))
              .toList();
          if (valid.isEmpty) continue;
          return AnimeSourceAdapter.bestMatch(q, valid, source);
        case Failure():
        case Loading():
          continue;
      }
    }
    return null;
  }

  static bool _overlaps(String query, String candidate) {
    final q = AnimeSourceAdapter.normalize(query);
    final c = AnimeSourceAdapter.normalize(candidate);
    if (q == c || q.contains(c) || c.contains(q)) return true;
    return q.split(' ').any(c.split(' ').contains);
  }

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    final url = Uri.parse('$baseUrl/?s=${Uri.encodeQueryComponent(query)}');
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
        // P9: the catalog serves films under `/filme/`; the video addresses are
        // under `/anime/` (TV) only.
        if (href.isEmpty || !href.contains('/anime/')) continue;
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
      debugPrint('[AnimesOnline] Search error: $e');
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
      final res = await _httpGet(Uri.parse(anime.url), headers: {'User-Agent': _ua});
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final list = <Episode>[];
      for (final card in doc.querySelectorAll('.episode-card')) {
        final numAttr = card.attributes['data-episode-number'];
        final a = card.querySelector('a[href*="/episodio/"]') ?? card.querySelector('a');
        final href = a?.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        final number = numAttr ?? (_episodeNumber(href)?.toString() ?? '');
        if (number.isEmpty) continue;
        list.add(Episode(
          number: number,
          url: href,
          source: source,
          owner: anime,
        ));
      }
      list.sort((a, b) {
        final na = int.tryParse(a.number);
        final nb = int.tryParse(b.number);
        if (na == null || nb == null) return 0;
        return na.compareTo(nb);
      });
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes found in HTML',
          source: source,
        ));
      }
      return ScraperResult.success(list);
} catch (e, st) {
      debugPrint('[AnimesOnline] Search stack: $st');
      debugPrint('[AnimesOnline] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Unexpected error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  int? _episodeNumber(String url) {
    final m = RegExp(r'episodio[^/]*?[-]?(\d+)\s*/?$').firstMatch(url);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final extractor = DooPlayV2Extractor(baseUrl: baseUrl, client: _client);
      final sources = await extractor.extractPlayable(episode.url);
      return ScraperResult.success(sources);
    } on NoPlayableOption catch (e) {
      // Layer B (last resort): probe the CDN directly by title + episode.
      final ctx = anime ?? episode.owner;
      final title = ctx?.name ?? '';
      final ep = int.tryParse(episode.number);
      if (title.isNotEmpty && ep != null) {
        try {
          final url = await CdnResolver(client: _client).resolve(title, ep,
              englishName: ctx?.englishName);
          if (url != null) {
            return ScraperResult.success([
              VideoSource(
                url: url,
                quality: 'Auto',
                headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'},
              ),
            ]);
          }
        } catch (e2) {
          debugPrint('[AnimesOnline] CDN fallback error: $e2');
        }
      }
      return ScraperResult.failure(EmptyResultError(
        message: 'No playable option: ${e.message}',
        source: source,
      ));
    } catch (e) {
      debugPrint('[AnimesOnline] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
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
}