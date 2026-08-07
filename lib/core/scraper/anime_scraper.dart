import 'package:flutter/foundation.dart';
import '../anilist/anilist_service.dart';
import '../cache/app_caches.dart';
import '../sources/source_registry.dart';
import '../utils/text_utils.dart';
import '../../data/models/anime.dart';
import 'scraper_result.dart';

/// Orchestration layer that aggregates search results from every
/// [AnimeSourceAdapter] and enriches them with AniList metadata (cached +
/// deduped).
///
/// Historically this also merged provider episode lists into a canonical grid.
/// Per the review, the CANONICAL GRID now lives in the catalog (AniList) via
/// [AnimeRepository.getCatalogEpisodes]; providers only resolve video on
/// demand. This class is left with the search aggregation only.
class AnimeScraper {
  static Future<List<Anime>> searchAnime(String animeName) async {
    // Fase C: strip scraped rating/age badges ("Naruto 7.93 A14") once before
    // the fan-out so no provider gets a dirty query.
    final query = TextUtils.cleanSearchQuery(animeName);
    final cacheKey = query.toLowerCase();
    final cached = AppCaches.search.get<List<Anime>>(cacheKey);
    if (cached != null) return cached;

    try {
      debugPrint('[AnimeScraper] Searching: $query');

      // Per-future error isolation: one adapter's unhandled exception does not
      // kill other adapter futures via Future.wait (Pitfall 1).
      final futures = SourceRegistry.adapters
          .where((a) => a.implemented)
          .map((a) async {
        try {
          return await a.search(query);
        } catch (e) {
          debugPrint('[AnimeScraper] Unhandled exception from ${a.source}: $e');
          return ScraperResult<List<Anime>>.failure(UnknownError(
            message: 'Unhandled: $e',
            source: a.source,
            originalError: e,
          ));
        }
      });
      final results = await Future.wait(futures);

      final allAnimes = <Anime>[];
      for (final result in results) {
        switch (result) {
          case Success(data: final animes):
            allAnimes.addAll(animes);
          case Failure(error: final err):
            // Per D-09: errors stay in log layer — UI sees empty states only
            debugPrint('[AnimeScraper] ${err.source} failed: ${err.message}');
          case Loading():
            break; // not produced in Phase 3, included for exhaustiveness
        }
      }

      // Filter out results that lack the identifier needed for episode loading.
      // This mirrors the validity check in _findBySource so that tapping a
      // search result always leads to resolvable episodes.
      bool hasValidId(Anime a) {
        switch (a.source) {
          case AnimeSource.allAnime:
            return a.allAnimeId != null;
          case AnimeSource.animeFire:
          case AnimeSource.goyabu:
          case AnimeSource.betterAnime:
          case AnimeSource.animesRoll:
          case AnimeSource.dooPlay:
          case AnimeSource.animePlayer:
            return a.url.isNotEmpty;
          case AnimeSource.anilist:
            return false; // metadata provider, no stream URL
        }
      }
      allAnimes.removeWhere((a) => !hasValidId(a));

      // Enrichment is cached + deduped per cleaned title inside AniListService,
      // so the same show appearing in multiple sources is only fetched once.
      await Future.wait(allAnimes.map((a) => AniListService.enrich(a)));

      // Prioritize PT-BR sources (stable sort keeps per-source order).
      allAnimes.sort((a, b) => a.source.priority.compareTo(b.source.priority));

      AppCaches.search.set(cacheKey, allAnimes);
      return allAnimes;
    } catch (e) {
      // Safety net — typed errors should be caught above
      debugPrint('[AnimeScraper] Search error: $e');
      return [];
    }
  }
}
