import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';

/// Port/adapter abstraction for every anime provider.
///
/// Each concrete source (AnimeFire, AllAnime, SuperFlix) knows how to:
///  - search its catalog for a query,
///  - list episodes for a given [Anime],
///  - resolve playable video sources for an [Episode].
///
/// All methods return [ScraperResult] so callers can distinguish success,
/// typed errors (timeout, parse failure, Cloudflare, empty results, unknown),
/// and handle each variant via exhaustive `switch` matching.
///
/// This decouples the orchestration layer ([AnimeScraper]) and the repository
/// from the scraping details, and makes adding a new provider a matter of
/// implementing this single interface.
abstract class AnimeSourceAdapter {
  AnimeSource get source;

  Future<ScraperResult<List<Anime>>> search(String query);

  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime);

  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  });
}
