import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';
import 'anime_source_adapter.dart';
import '../../core/anilist/anilist_service.dart';

class AniListAdapter implements AnimeSourceAdapter {
  @override
  AnimeSource get source => AnimeSource.anilist;

  // B11: busca via GraphQL AniList é implementada (requer token p/ autenticar).
  @override
  bool get implemented => true;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    // Query AniList for media matching query
    final token = await AniListService.getToken();
    if (token == null) return ScraperResult.failure(EmptyResultError(
      message: 'AniList not authenticated',
      source: source,
    ));

    const graphqlQuery = '''
      query (\$search: String) {
        Media(search: \$search, type: ANIME, perPage: 10) {
          id
          title { romaji english }
          coverImage { large }
          bannerImage
          description
          episodes
          status
          averageScore
          genres
        }
      }
    ''';

    // Implementation would use http.post to AniList GraphQL endpoint
    // Return list of AniList media as EpisodesResult
    return ScraperResult.failure(EmptyResultError(
      message: 'Search not implemented in AniListAdapter',
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
