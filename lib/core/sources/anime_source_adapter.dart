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

  /// B11: whether this source has a real, usable search. Non-implemented
  /// adapters are excluded from the parallel search fan-out so one query
  /// doesn't fire ~12 dead requests.
  bool get implemented => true;

  // search method removed - currently unused
  // Future<ScraperResult<List<Anime>>> search(String query);

  Future<ScraperResult<List<Anime>>> search(String query);

  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime);

  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  });

  /// Check availability with detailed diagnosis
  Future<AvailabilityReport> checkAvailability(String animeName);
}

  /// Report of availability check for a specific anime and source
  final class AvailabilityReport {
    final AnimeSource source;
    final String animeName;
    late final AvailabilityStatus status;
    String? reason;
    int? episodeCount;
    String? usedVariation;

    AvailabilityReport({
      required this.source,
      required this.animeName,
    });
  }

  /// Status of availability check
  enum AvailabilityStatus {
    available,         // Anime encontrado
    notFound,          // Anime não existe
    foundWithVariation,// Encontrado com nome alternativo
    error,             // Erro desconhecido
    timeout,           // Timeout
    exception,         // Exceção
  }
