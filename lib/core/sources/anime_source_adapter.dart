import '../../data/models/anime.dart';
import '../../data/models/episode.dart';

/// Port/adapter abstraction for every anime provider.
///
/// Each concrete source (AnimeFire, AllAnime, SuperFlix) knows how to:
///  - search its catalog for a query,
///  - list episodes for a given [Anime],
///  - resolve playable video sources for an [Episode].
///
/// This decouples the orchestration layer ([AnimeScraper]) and the repository
/// from the scraping details, and makes adding a new provider a matter of
/// implementing this single interface.
abstract class AnimeSourceAdapter {
  AnimeSource get source;

  Future<List<Anime>> search(String query);

  Future<EpisodesResult> getEpisodes(Anime anime);

  Future<List<VideoSource>> getVideoSources(
    Episode episode, {
    Anime? anime,
  });
}
