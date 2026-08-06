import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'dart:async' show TimeoutException;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';
import '../sources/anime_source_adapter.dart';

class AnikyuuAdapter implements AnimeSourceAdapter {
  @override
  AnimeSource get source => AnimeSource.anikyuu;
  @override
  bool get implemented => false;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    return ScraperResult.failure(EmptyResultError(
      message: 'Anikyuu search not implemented',
      source: source,
    ));
  }

  @override
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
    debugPrint('[AnikyuuAdapter] getEpisodes START anime=${anime.name}');
    debugPrint('[AnikyuuAdapter] anime.url=${anime.url}');

    if (anime.url.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Empty anime URL',
        source: source,
      ));
    }

    final stopwatch = Stopwatch()..start();

    try {
      final uri = Uri.parse(anime.url);
      debugPrint('[AnikyuuAdapter] Fetching episodes from: $uri');

      final res = await http.Client().get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0',
        },
      ).timeout(
        Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('Request timed out'),
      );

      debugPrint('[AnikyuuAdapter] Response status: ${res.statusCode}');

      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }

      final doc = html_parser.parse(res.body);
      debugPrint('[AnikyuuAdapter] Parsed HTML, looking for episodes');

      // Procurar por elementos de episódio
      final episodeElements = doc.querySelectorAll('.eps1');

      debugPrint('[AnikyuuAdapter] Found ${episodeElements.length} episode elements');

      final episodeUrls = <String>[];
      for (final element in episodeElements) {
        final linkElement = element.querySelector('a[href]');
        if (linkElement != null) {
          final href = linkElement.attributes['href'];
          if (href != null && href.isNotEmpty) {
            final episodeUrl = Uri.parse(href).replace(
              scheme: 'https',
              host: 'anikyuu.to',
            );
            episodeUrls.add(episodeUrl.toString());
          }
        }
      }

      if (episodeUrls.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episode URLs found in HTML',
          source: source,
        ));
      }

      final episodes = episodeUrls.asMap().entries.map((entry) {
        final num = entry.key + 1;
        return Episode(
          number: num.toString(),
          url: entry.value,
          source: source,
          owner: anime,
        );
      }).toList();

      return ScraperResult.success(EpisodesResult(
        episodes,
        {source.toString(): episodes},
      ));

    } catch (e, stackTrace) {
      debugPrint('[AnikyuuAdapter] getEpisodes ERROR: $e\n$stackTrace');
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
    return ScraperResult.failure(EmptyResultError(
      message: 'Anikyuu video sources not implemented',
      source: source,
    ));
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
