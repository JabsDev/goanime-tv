import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';
import 'anime_source_adapter.dart';
// diagnostic_mixin removed - not used in current implementation
// encryption fields removed - currently disabled

/// AllAnime provider: EN source with captcha protection (currently disabled)
class AllAnimeAdapter implements AnimeSourceAdapter {
  // Encryption fields removed - currently disabled
  // final enc.Key _key;
  // final Uint8List _iv;

  AllAnimeAdapter();

  @override
  AnimeSource get source => AnimeSource.allAnime;
  @override
  bool get implemented => false;

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    // AllAnime currently requires captcha, so return empty
    return ScraperResult.failure(
      EmptyResultError(
        message: 'AllAnime requires captcha verification',
        source: source,
      ),
    );
  }

  @override
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
    return ScraperResult.failure(
      EmptyResultError(
        message: 'AllAnime requires captcha verification',
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
        message: 'AllAnime requires captcha verification',
        source: source,
      ),
    );
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
