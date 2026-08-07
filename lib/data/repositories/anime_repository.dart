import 'package:flutter/foundation.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/cache/app_caches.dart';
import '../../core/scraper/anime_scraper.dart';
import '../../core/sources/anime_source_adapter.dart';
import '../../core/sources/source_registry.dart';
import '../../core/storage/provider_match_store.dart';
import '../models/anime.dart';
import '../models/episode.dart';

/// Port for the UI. Owns the two orchestration flows:
///
///  - [getCatalogEpisodes]: the canonical grid, built exclusively from the
///    catalog (AniList) — 1..N, never from a provider.
///  - [resolveProvidersForEpisode]: on-demand fan-out that asks every provider
///    "do you have episode N?" in parallel (error-isolated), reusing the
///    PERSISTED provider match so the second tap on a show is search-free.
///
/// The provider never defines the grid; it only resolves video.
class AnimeRepository {
  Future<List<Anime>> searchAnime(String query) async {
    return AnimeScraper.searchAnime(query);
  }

  /// Canonical episode list for the grid. Built from AniList: per-episode
  /// titles/thumbs come from `episodesV2` when logged in; otherwise a plain
  /// 1..N range from `anime.episodes`. The result carries no provider data.
  Future<List<CatalogEpisode>> getCatalogEpisodes(Anime anime) async {
    final identity = ProviderMatchStore.identity(anime);
    final cached = AppCaches.catalog.get<List<CatalogEpisode>>(identity);
    if (cached != null) return cached;

    var eps = <CatalogEpisode>[];
    if (anime.anilistId != null) {
      // Logged-in AniList exposes per-episode metadata; anonymous returns []
      // and we fall back to the plain 1..N range below.
      final v2 = await AniListService.getEpisodesV2(anime.anilistId!);
      eps = v2
          .where((e) => int.tryParse(e.number) != null)
          .map((e) => CatalogEpisode(
                number: int.parse(e.number),
                title: e.title,
                thumbnail: e.thumbnail,
                description: e.description,
              ))
          .toList()
        ..sort((a, b) => a.number.compareTo(b.number));
    }

    if (eps.isEmpty) {
      final total = anime.episodes ?? 0;
      if (total > 0) {
        eps = [for (var i = 1; i <= total; i++) CatalogEpisode(number: i)];
      }
    }

    AppCaches.catalog.set(identity, eps);
    return eps;
  }

  /// Asks every implemented provider for episode [episodeNumber] of [anime] in
  /// parallel. Returns a map provider → playable resolutions, ordered by
  /// priority; providers without the episode (or that failed) are absent.
  ///
  /// The provider's page match is persisted via [ProviderMatchStore], so only
  /// the first tap on a show pays a search-by-name per provider.
  Future<Map<AnimeSource, List<VideoSource>>> resolveProvidersForEpisode(
    Anime anime,
    int episodeNumber,
  ) async {
    final identity = ProviderMatchStore.identity(anime);
    final cacheKey = '$identity:$episodeNumber';
    final cached =
        AppCaches.resolutions.get<Map<AnimeSource, List<VideoSource>>>(cacheKey);
    if (cached != null) return cached;

    final results = <AnimeSource, List<VideoSource>>{};
    final adapters =
        SourceRegistry.adapters.where((a) => a.implemented).toList();

    Future<void> resolve(AnimeSourceAdapter adapter) async {
      final src = adapter.source;
      try {
        // 1. Reuse the persisted page match when available (no network).
        var match = Anime(name: anime.name, url: '', source: src);
        final persisted = await ProviderMatchStore.urlFor(identity, src);
        if (persisted != null && persisted.isNotEmpty) {
          match = Anime(name: anime.name, url: persisted, source: src);
        } else {
          // 2. First hit: locate the page (search-by-name) and persist it.
          final found = await adapter.resolveAnime(anime);
          if (found == null || found.url.isEmpty) return;
          match = found;
          await ProviderMatchStore.saveMatch(identity, src, found.url);
        }
        if (match.url.isEmpty) return;

        // 3. Resolve the stream(s) of episode N on that page.
        final sources = await adapter.resolveVideo(match, episodeNumber);
        if (sources.isNotEmpty) results[src] = sources;
      } catch (e) {
        debugPrint(
            '[Repo] resolve ep $episodeNumber on $src failed: $e');
      }
    }

    await Future.wait(adapters.map(resolve));

    // Stable priority ordering for display (AnimeFire first).
    final keys = results.keys.toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final ordered = <AnimeSource, List<VideoSource>>{
      for (final k in keys) k: results[k]!,
    };

    AppCaches.resolutions.set(cacheKey, ordered);
    return ordered;
  }
}