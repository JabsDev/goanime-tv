import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';
import 'anime_source_adapter.dart';
import '../../core/anilist/anilist_service.dart';

class AniListAdapter implements AnimeSourceAdapter {
  @override
  AnimeSource get source => AnimeSource.anilist;

  // AniList is a metadata provider (titles, episode info, score) — NOT a
  // stream source. It must not participate in the search fan-out or the video
  // fallback order, so `implemented` is false (excludes it from those paths).
  @override
  bool get implemented => false;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    // Metadata provider (like IMDB): never a stream source, so it returns no
    // search hits — AniList data flows in via AniListService.enrich instead.
    return ScraperResult.failure(EmptyResultError(
      message: 'AniList is a metadata provider, not a stream source',
      source: source,
    ));
  }

  @override
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
    if (anime.anilistId == null) {
      return ScraperResult.failure(EmptyResultError(
        message: 'AniList ID not available',
        source: source,
      ));
    }

    try {
      final episodes = await AniListService.getEpisodesV2(anime.anilistId!);
      final episodeList = episodes.map((e) => Episode(
            number: e.number,
            url: anime.url, // Use anime URL as fallback for streaming
            thumbnail: e.thumbnail,
            title: e.title,
            description: e.description,
            source: AnimeSource.anilist,
            owner: anime,
          )).toList();

      return ScraperResult.success(EpisodesResult(
        episodeList,
        {source.toString(): episodeList},
      ));
    } catch (e) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Failed to fetch AniList episodes: $e',
        source: source,
      ));
    }
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(Episode episode, {Anime? anime}) async {
    // No video streams from AniList
    return ScraperResult.failure(EmptyResultError(
      message: 'AniList does not provide video streams',
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
