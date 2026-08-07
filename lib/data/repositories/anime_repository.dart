import 'package:flutter/foundation.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/cache/app_caches.dart';
import '../../core/scraper/anime_scraper.dart';
import '../../core/scraper/scraper_result.dart';
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
  AnimeRepository({List<AnimeSourceAdapter>? adapters})
      : _adapters = adapters ?? SourceRegistry.adapters;

  final List<AnimeSourceAdapter> _adapters;

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

    // Catalog didn't report a total (e.g. AniList RELEASING series have
    // episodes:null). Stand in as many cards as the first reachable provider
    // serves, so the grid isn't empty for the biggest shows.
    if (eps.isEmpty) {
      final fromProvider = await _episodeCountFromProviders(anime);
      if (fromProvider > 0) {
        eps = [for (var i = 1; i <= fromProvider; i++) CatalogEpisode(number: i)];
      }
    }

    AppCaches.catalog.set(identity, eps);
    return eps;
  }

  /// Breaks on the first provider that delivers an episode count — for a
  /// RELEASING series (AniList episodes:null) or when AniList enrichment
  /// failed, so a series still gets a numbered grid. Best effort — no provider
  /// is guaranteed to respond.
  Future<int> _episodeCountFromProviders(Anime anime) async {
    for (final adapter in _adapters) {
      if (!adapter.implemented) continue;
      try {
        // Reuse the page the anime already carries (e.g. from a search result)
        // before falling back to a name search. Only when it belongs to this
        // adapter, so a goyabu URL isn't fed to the animeFire parser.
        var target = anime.url.isNotEmpty && anime.source == adapter.source
            ? anime
            : await adapter.resolveAnime(anime);
        if (target == null || target.url.isEmpty) continue;
        final eps = await adapter.getEpisodes(target);
        switch (eps) {
          case Success(data: final data):
            if (data.isNotEmpty) return data.length;
          case Failure():
          case Loading():
            break;
        }
      } catch (_) {
        continue;
      }
    }
    return 0;
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
    final adapters = _adapters.where((a) => a.implemented).toList();

    Future<void> resolve(AnimeSourceAdapter adapter) async {
      final src = adapter.source;
      try {
        // 1. Reuse the persisted page match when available (no network).
        var match = Anime(name: anime.name, url: '', source: src);
        final persisted = await ProviderMatchStore.urlFor(identity, src);
        var freshlyFound = false;
        if (persisted != null && persisted.isNotEmpty) {
          match = Anime(name: anime.name, url: persisted, source: src);
        } else {
          // 2. First hit: locate the page (search-by-name); don't persist yet —
          //    only a page that delivers the requested episode is worth saving.
          final found = await adapter.resolveAnime(anime);
          if (found == null || found.url.isEmpty) return;
          match = found;
          freshlyFound = true;
        }
        if (match.url.isEmpty) return;

        // 3. Resolve the stream(s) of episode N on that page.
        final sources = await adapter.resolveVideo(match, episodeNumber);
        if (sources.isEmpty) {
          // The page neither matched nor holds episode N. Drop a persisted
          // page so the next tap re-discovers instead of replaying a dead one.
          if (persisted != null && persisted.isNotEmpty) {
            await ProviderMatchStore.removeMatch(identity, src);
          }
          return;
        }
        results[src] = sources;
        // Persist only after the page delivered >=1 source for the episode.
        if (freshlyFound) {
          await ProviderMatchStore.saveMatch(identity, src, match.url);
        }
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