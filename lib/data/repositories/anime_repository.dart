import 'package:flutter/foundation.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/cache/app_caches.dart';
import '../../core/scraper/anime_scraper.dart';
import '../../core/scraper/scraper_result.dart';
import '../../core/sources/anime_source_adapter.dart';
import '../../core/sources/source_registry.dart';
import '../../core/storage/provider_match_store.dart';
import '../models/anime.dart';
import '../models/anilist_models.dart';
import '../models/episode.dart';

/// Result of fanning out an episode across every provider. Beyond the
/// providers that delivered video, it tracks why each missing provider is
/// missing: the page matched but the extractor found nothing
/// ([matchedUnavailable] — e.g. Blogger SPA) versus the page not being found
/// at all ([notFound]).
class EpisodeResolution {
  final Map<AnimeSource, List<VideoSource>> providers;
  final Set<AnimeSource> matchedUnavailable;
  final Set<AnimeSource> notFound;

  const EpisodeResolution({
    required this.providers,
    required this.matchedUnavailable,
    required this.notFound,
  });
}

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

  /// Canonical episode list for the grid. Always a contiguous 1..N range; N
  /// comes from AniList [Anime.episodes], falling back to a provider count and
  /// finally to the highest number seen in `episodesV2`. The AniList per-episode
  /// metadata (`v2`) never defines the grid — it only decorates titles/thumbs
  /// by real episode number, so a partial/descending payload can't produce an
  /// out-of-order or short grid. Cache is keyed by session state (v2 vs v1) so a
  /// logged-out grid isn't served to a logged-in user (and vice versa).
  Future<List<CatalogEpisode>> getCatalogEpisodes(Anime anime) async {
    final identity = ProviderMatchStore.identity(anime);
    final logged = await AniListService.isLoggedIn();
    final cacheKey = '$identity|${logged ? 'v2' : 'v1'}|gridV2';
    final cached = AppCaches.catalog.get<List<CatalogEpisode>>(cacheKey);
    if (cached != null) return cached;

    var v2 = <AniListEpisode>[];
    if (anime.anilistId != null) {
      v2 = await AniListService.getEpisodesV2(anime.anilistId!);
    }

    // Canonical total: AniList count → provider count → digits present in v2.
    var total = anime.episodes ?? 0;
    if (total <= 0) total = await _episodeCountFromProviders(anime);
    if (total <= 0) {
      for (final e in v2) {
        final n = int.tryParse(e.number);
        if (n != null && n > total) total = n;
      }
    }
    if (total <= 0) {
      AppCaches.catalog.set(cacheKey, const <CatalogEpisode>[]);
      return const [];
    }

    // Decoration map: real number → episode card data, out-of-range and
    // duplicate numbers dropped.
    final byNumber = <int, AniListEpisode>{};
    for (final e in v2) {
      final n = int.tryParse(e.number);
      if (n == null || n < 1 || n > total) continue;
      if (byNumber.containsKey(n)) continue;
      byNumber[n] = e;
    }

    final eps = [
      for (var i = 1; i <= total; i++)
        CatalogEpisode(
          number: i,
          title: byNumber[i]?.title,
          thumbnail: byNumber[i]?.thumbnail,
          description: byNumber[i]?.description,
        ),
    ];

    AppCaches.catalog.set(cacheKey, eps);
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
  /// parallel. Returns a resolution with provider → playable resolutions
  /// (ordered by priority) plus the classification of providers that didn't
  /// deliver: page matched but extractor failed (`matchedUnavailable`) vs page
  /// not found (`notFound`).
  ///
  /// The provider's page match is persisted via [ProviderMatchStore], so only
  /// the first tap on a show pays a search-by-name per provider. A matched page
  /// that resolves no video keeps its persisted match (the page is valid; the
  /// extractor is what failed) — only genuinely absent pages are dropped.
  Future<EpisodeResolution> resolveProvidersForEpisode(
    Anime anime,
    int episodeNumber,
  ) async {
    final identity = ProviderMatchStore.identity(anime);
    final cacheKey = '$identity:$episodeNumber';
    // Only the happy-path map is cached; unavailable/notFound states are cheap
    // to re-derive and shouldn't stick for 30 minutes.
    final cached =
        AppCaches.resolutions.get<Map<AnimeSource, List<VideoSource>>>(cacheKey);
    if (cached != null) {
      return EpisodeResolution(
        providers: cached,
        matchedUnavailable: const {},
        notFound: const {},
      );
    }

    final results = <AnimeSource, List<VideoSource>>{};
    final matchedUnavailable = <AnimeSource>{};
    final notFound = <AnimeSource>{};
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
          if (found == null || found.url.isEmpty) {
            notFound.add(src);
            return;
          }
          match = found;
          freshlyFound = true;
        }
        if (match.url.isEmpty) {
          notFound.add(src);
          return;
        }

        // 3. Resolve the stream(s) of episode N on that page.
        final sources = await adapter.resolveVideo(match, episodeNumber);
        if (sources.isEmpty) {
          // Page exists but no video resolved (Blogger SPA, or the episode just
          // isn't indexable here). The persisted match is kept so the next tap
          // doesn't re-pay the search.
          matchedUnavailable.add(src);
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

    if (ordered.isNotEmpty) {
      AppCaches.resolutions.set(cacheKey, ordered);
    }
    return EpisodeResolution(
      providers: ordered,
      matchedUnavailable: matchedUnavailable,
      notFound: notFound,
    );
  }
}