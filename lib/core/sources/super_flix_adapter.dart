import 'package:flutter/foundation.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';
import 'anime_source_adapter.dart';
// diagnostic_mixin removed - not used in current implementation

/// SuperFlix provider (EN): TMDB-based anime streaming site
class SuperFlixAdapter implements AnimeSourceAdapter {
  // _client field removed - not used in current implementation

  @override
  AnimeSource get source => AnimeSource.superFlix;
  @override
  bool get implemented => false;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    debugPrint('[SuperFlix] Search: $query');
    return ScraperResult.failure(
      EmptyResultError(
        message: 'SuperFlix search not implemented',
        source: source,
      ),
    );
  }

  @override
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
    return ScraperResult.failure(
      EmptyResultError(
        message: 'SuperFlix episodes not implemented',
        source: source,
      ),
    );
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    return ScraperResult.failure(
      EmptyResultError(
        message: 'SuperFlix video sources not implemented',
        source: source,
      ),
    );
  }

  Future<List<VideoSource>?> resolveExternalServer(String url, String name) async {
    debugPrint('[SuperFlix] resolveExternalServer: $name - $url');
    return null;
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
