import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../constants/app_constants.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// Goyabu provider (PT-BR): HTML scraping for search and episode listing,
/// video via the `layersData` HLS proxy URL embedded in the episode page.
class GoyabuAdapter implements AnimeSourceAdapter {
  final http.Client? _client;

  GoyabuAdapter({http.Client? client}) : _client = client;

  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) {
      return _client.get(uri, headers: headers);
    }
    return apiClient.get(uri, headers: headers);
  }

  static const _base = 'https://goyabu.io';
  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  @override
  AnimeSource get source => AnimeSource.goyabu;
  @override
  bool get implemented => true;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    final url = Uri.parse(
        '$_base/?s=${Uri.encodeQueryComponent(TextUtils.cleanSearchQuery(query))}');
    try {
      http.Response res;
      try {
        res = await _httpGet(url, headers: {
          'User-Agent': _userAgent,
          'Accept-Language': 'pt-BR,pt;q=0.9',
        });
      } on TimeoutException {
        res = await _httpGet(url, headers: {
          'User-Agent': _userAgent,
          'Accept-Language': 'pt-BR,pt;q=0.9',
        });
      }
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final list = <Anime>[];
      for (final article in doc.querySelectorAll('article.boxAN')) {
        final a = article.querySelector('a');
        final href = a?.attributes['href'] ?? '';
        if (href.isEmpty || !href.contains('/anime/')) continue;
        final img = article.querySelector('img.cover');
        final name = TextUtils.cleanTitle(
          img?.attributes['alt'] ??
              a?.text.trim() ??
              href.split('/').last,
        );
        if (name.isEmpty) continue;
        list.add(Anime(
          name: name,
          url: href,
          source: AnimeSource.goyabu,
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
      debugPrint('[Goyabu] Search error: $e');
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
        'User-Agent': _userAgent,
        'Accept-Language': 'pt-BR,pt;q=0.9',
      });
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }

      // Goyabu embeds the episode list as a JS array literal:
      //   var allEpisodes = [{"id":50866,"episodio":"1","link":"/50866",...}]
      final match = RegExp(r'allEpisodes\s*=\s*(\[.*?\]);')
          .firstMatch(res.body);
      if (match == null) {
        // Fase C: some pages use a different embedding — fall back to parsing
        // episode anchor links before giving up.
        final fallback = _parseEpisodesFallback(res.body, anime);
        if (fallback.isEmpty) {
          return ScraperResult.failure(EmptyResultError(
            message: 'No episodes JSON found',
            source: source,
          ));
        }
        return ScraperResult.success(EpisodesResult(
          fallback,
          {source.toString(): fallback},
        ));
      }

      final decoded = jsonDecode(match.group(1)!);
      if (decoded is! List || decoded.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Empty episode list',
          source: source,
        ));
      }

      final episodes = <Episode>[];
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString() ?? '';
        final num = raw['episodio']?.toString() ?? '';
        final link = raw['link']?.toString() ?? '/$id';
        if (id.isEmpty) continue;
        episodes.add(Episode(
          number: num.isEmpty ? id : num,
          url: link.startsWith('http') ? link : '$_base$link',
          title: raw['episode_name']?.toString(),
          source: source,
          owner: anime,
        ));
      }
      if (episodes.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed',
          source: source,
        ));
      }
      return ScraperResult.success(EpisodesResult(
        episodes,
        {source.toString(): episodes},
      ));
    } catch (e) {
      debugPrint('[Goyabu] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Fallback episode parser for pages that don't embed `allEpisodes`: scans
  /// anchor links whose href/text carries an episode number (e.g. `/episodio-3`).
  List<Episode> _parseEpisodesFallback(String body, Anime anime) {
    final doc = html_parser.parse(body);
    final episodes = <Episode>[];
    final seen = <String>{};
    final numRe =
        RegExp(r'(?:episodio|ep-?|eps)[\-_ ]?(\d+)', caseSensitive: false);
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      final numMatch = numRe.firstMatch(href);
      if (numMatch == null) continue;
      final url = href.startsWith('http') ? href : '$_base$href';
      if (!seen.add(url)) continue;
      episodes.add(Episode(
        number: numMatch.group(1)!,
        url: url,
        title: a.text.trim(),
        source: source,
        owner: anime,
      ));
    }
    episodes.sort((a, b) =>
        (int.tryParse(a.number) ?? 0).compareTo(int.tryParse(b.number) ?? 0));
    return episodes;
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final sources = await _extractFromGoyabu(episode.url);
      if (sources.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No video sources found',
          source: source,
        ));
      }
      return ScraperResult.success(sources);
    } catch (e) {
      debugPrint('[Goyabu] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Extracts the HLS URL from a Goyabu episode page. The page embeds a
  /// `layersData` JS array whose first entry has an `url` pointing to the
  /// site's HLS proxy (`api.anivideo.fun/videohls.php?d=<m3u8>`).
  Future<List<VideoSource>> _extractFromGoyabu(String episodeUrl) async {
    final res = await _httpGet(Uri.parse(episodeUrl), headers: {
      'User-Agent': _userAgent,
      'Referer': '$_base/',
      'Accept-Language': 'pt-BR,pt;q=0.9',
    });
    if (res.statusCode != 200) return [];

    final match = RegExp(r'layersData\s*=\s*(\[.*?\]);').firstMatch(res.body);
    if (match == null) return [];

    final decoded = jsonDecode(match.group(1)!);
    if (decoded is! List) return [];

    final urls = <String>{};
    for (final layer in decoded) {
      if (layer is! Map) continue;
      final url = layer['url']?.toString() ?? '';
      if (url.isEmpty) continue;
      // Prefer the embedded HLS proxy URL; fall back to a raw m3u8.
      if (url.contains('videohls.php') || url.contains('.m3u8')) {
        urls.add(url);
      }
    }
    if (urls.isEmpty) return [];

    final headers = {
      'User-Agent': AppConstants.userAgent,
      'Referer': '$_base/',
    };
    return urls.map((u) => VideoSource(url: u, quality: 'Auto', headers: headers)).toList();
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
