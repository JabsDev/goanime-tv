import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/cache/app_caches.dart';
import '../../core/scraper/anime_scraper.dart';
import '../../core/scraper/scraper_result.dart';
import '../../core/sources/anime_source_adapter.dart';
import '../../core/sources/source_registry.dart';
import '../../core/storage/provider_match_store.dart';
import '../../core/utils/episode_number.dart';
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

  /// Providers that threw or timed out (8s step budget). Unlike the other
  /// sets this is transient — a retry may succeed — so the dialog offers
  /// "try again" instead of silence when nothing else delivered.
  final Set<AnimeSource> errored;

  /// True when every implemented provider has already been asked (cache hit or
  /// the full fan-out finished). During a progressive (`partial`) resolution
  /// the UI uses this to keep a loading state until the last provider lands —
  /// a timing-full `providers` that is not yet [complete] can still grow.
  final bool complete;

  const EpisodeResolution({
    required this.providers,
    required this.matchedUnavailable,
    required this.notFound,
    this.errored = const {},
    this.complete = true,
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

  /// Per-call budget for a provider step (page match or video extraction). A
  /// provider that exceeds it is dropped from the resolution instead of
  /// stalling the rest — dead/cloudflare-gated sources can no longer hold the
  /// episode picker hostage for up to 30s × retries.
  static const Duration providerStepTimeout = Duration(seconds: 8);

  /// In `partial` mode, how long to wait for the best provider to produce
  /// video before returning with what's already resolved. The providers still
  /// running continue in the background and stream in via [onUpdate].
  static const Duration partialGateDeadline = Duration(milliseconds: 3500);

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
    // Provider-fallback grids (AniList down) on combined pages are ABSOLUTE
    // (AnimeFire 1..94 mixes S1..S4); season labels keep "EP 21" from reading
    // as S4E21. Only unambiguous number→season mappings label rows.
    var total = anime.episodes ?? 0;
    var seasonLabels = const <int, String>{};
    if (total <= 0) {
      final fallback = await _countAndSeasonsFromProviders(anime);
      total = fallback.total;
      seasonLabels = fallback.seasonLabels;
    }
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
          seasonLabel: seasonLabels[i],
        ),
    ];

    AppCaches.catalog.set(cacheKey, eps);
    return eps;
  }

  /// Breaks on the first provider that delivers an episode count — for a
  /// RELEASING series (AniList episodes:null) or when AniList enrichment
  /// failed, so a series still gets a numbered grid. Counts the HIGHEST
  /// episode number, not the list length: a partial/paginated provider page
  /// must not shrink the grid. Best effort — no provider is guaranteed to
  /// respond.
  ///
  /// Also returns season labels for rows whose number maps to exactly ONE
  /// season on that page (AnimeFire absolute 1..94 → T1..T4). Collapsed
  /// numbers (DooPlay combined: four season-21s) stay unlabeled rather than
  /// guess — no badge beats a wrong badge.
  Future<({int total, Map<int, String> seasonLabels})>
      _countAndSeasonsFromProviders(Anime anime) async {
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
            var max = 0;
            final seasonsByNumber = <int, Set<int?>>{};
            for (final e in data) {
              final n = int.tryParse(e.number) ??
                  episodeNumberFromUrl(e.url) ??
                  0;
              if (n > max) max = n;
              if (n > 0) {
                seasonsByNumber.putIfAbsent(n, () => {}).add(e.season);
              }
            }
            if (max <= 0) continue;
            final labels = <int, String>{};
            for (final entry in seasonsByNumber.entries) {
              final seasons = entry.value.whereType<int>().toList();
              // Unambiguous only: exactly one distinct season AND no
              // season-less episode sharing the number.
              if (seasons.length == 1 &&
                  entry.value.length == 1) {
                labels[entry.key] = 'T${seasons.single}';
              }
            }
            return (total: max, seasonLabels: labels);
          case Failure():
          case Loading():
            break;
        }
      } catch (_) {
        continue;
      }
    }
    return (total: 0, seasonLabels: const <int, String>{});
  }

  /// Page-level health probe for a persisted provider match: true when the
  /// page still lists at least one episode. Time-boxed like every other
  /// provider step; any failure counts as dead so the caller drops the stale
  /// match and re-discovers instead of replaying a dead page forever.
  Future<bool> _pageAlive(AnimeSourceAdapter adapter, Anime match) async {
    try {
      final eps =
          await adapter.getEpisodes(match).timeout(providerStepTimeout);
      return switch (eps) {
        Success(data: final data) => data.isNotEmpty,
        _ => false,
      };
    } catch (_) {
      return false;
    }
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
  ///
  /// Each provider is time-boxed by [providerStepTimeout], so a hung/dead
  /// source is dropped instead of gating the others.
  ///
  /// When [partial] is true the future completes as soon as the best-priority
  /// provider that delivers video is final (or after [partialGateDeadline]),
  /// so the picker opens without waiting for the slowest provider; providers
  /// still running carry on in the background and [onUpdate] is invoked with an
  /// incremental resolution each time one of them lands. The returned
  /// [EpisodeResolution.complete] reflects whether the snapshot is final. The
  /// default (`partial: false`) preserves the old blocking semantics — full
  /// fan-out awaited — used by the player re-resolve and prefetch paths.
  Future<EpisodeResolution> resolveProvidersForEpisode(
    Anime anime,
    int episodeNumber, {
    bool partial = false,
    void Function(EpisodeResolution resolution)? onUpdate,
  }) async {
    final identity = ProviderMatchStore.identity(anime);
    final cacheKey = '$identity:$episodeNumber';
    // Only the happy-path map is cached; unavailable/notFound states are cheap
    // to re-derive and shouldn't stick for 30 minutes.
    final cached =
        AppCaches.resolutions.get<Map<AnimeSource, List<VideoSource>>>(cacheKey);
    if (cached != null) {
      final resolution = EpisodeResolution(
        providers: cached,
        matchedUnavailable: const {},
        notFound: const {},
        errored: const {},
        complete: true,
      );
      // BUGFIX (fontes não carregam na 2ª abertura): o cache hit retornava antes
      // do fan-out e NUNCA chamava o `onUpdate` — o consumidor (_ProviderQualityDialog)
      // dependia do onUpdate para sair de `_loading=true`. Ao reabrir o mesmo ep
      // dentro do TTL, o diálogo ficava eternamente em "Procurando fontes de
      // vídeo...". Alimenta o consumidor com a resolução cacheada como progresso.
      if (onUpdate != null) onUpdate(resolution);
      return resolution;
    }

    final results = <AnimeSource, List<VideoSource>>{};
    final matchedUnavailable = <AnimeSource>{};
    final notFound = <AnimeSource>{};
    final errored = <AnimeSource>{};
    final adapters = _adapters.where((a) => a.implemented).toList();
    final done = <AnimeSource>{};

    // Best-effort snapshot of the current (possibly partial) resolution.
    EpisodeResolution snapshot() {
      final keys = results.keys.toList()
        ..sort((a, b) => a.priority.compareTo(b.priority));
      final ordered = <AnimeSource, List<VideoSource>>{
        for (final k in keys) k: results[k]!,
      };
      return EpisodeResolution(
        providers: ordered,
        matchedUnavailable: {...matchedUnavailable},
        notFound: {...notFound},
        errored: {...errored},
        complete: done.length == adapters.length,
      );
    }

    // Time-boxes a single provider step so a slow source can't block the rest.
    Future<T> step<T>(Future<T> Function() op) {
      return op().timeout(providerStepTimeout);
    }

    // Fires the partial gate once the best provider with video is final (or
    // everything is done). Non-null only in `partial` mode.
    Completer<void>? gate;
    bool useGate = false;
    if (partial && adapters.isNotEmpty) {
      gate = Completer<void>();
      useGate = true;
    }
    void checkGate() {
      final g = gate;
      if (g == null || g.isCompleted) return;
      AnimeSource? best;
      for (final k in results.keys) {
        if (best == null || k.priority < best.priority) best = k;
      }
      if (best != null && done.contains(best)) {
        g.complete();
      } else if (done.length == adapters.length) {
        g.complete();
      }
    }

    void maybeCache() {
      if (done.length != adapters.length || results.isEmpty) return;
      AppCaches.resolutions.set(cacheKey, snapshot().providers);
    }

    Future<void> resolve(AnimeSourceAdapter adapter) async {
      final src = adapter.source;
      try {
        // 1. Reuse the persisted page match when available (no network).
        var match = Anime(name: anime.name, url: '', source: src);
        final persisted = await ProviderMatchStore.urlFor(identity, src);
        if (persisted != null && persisted.isNotEmpty) {
          match = Anime(name: anime.name, url: persisted, source: src);
          // Page-level probe: a persisted page that no longer lists episodes
          // (site migration, removed title) is dropped and re-discovered in
          // step 2 instead of pinning every episode to matchedUnavailable.
          // A page that lists episodes but yields no video keeps its match
          // (the extractor is what failed, not the page).
          if (!await _pageAlive(adapter, match)) {
            await ProviderMatchStore.removeMatch(identity, src);
            match = Anime(name: anime.name, url: '', source: src);
          }
        }
        if (match.url.isEmpty) {
          // 2. First hit: locate the page (search-by-name). The page-level
          //    match is persisted right away — even if this episode's
          //    extraction fails (Blogger SPA, timeout), the next tap skips the
          //    search-by-name instead of re-paying it.
          final found = await step(() => adapter.resolveAnime(anime));
          if (found == null || found.url.isEmpty) {
            notFound.add(src);
            return;
          }
          match = found;
          await ProviderMatchStore.saveMatch(identity, src, match.url);
        }
        if (match.url.isEmpty) {
          notFound.add(src);
          return;
        }

        // 3. Resolve the stream(s) of episode N on that page.
        final sources = await step(() =>
            adapter.resolveVideo(match, episodeNumber, catalog: anime));
        if (sources.isEmpty) {
          // Page exists but no video resolved (Blogger SPA, or the episode just
          // isn't indexable here). The persisted match is kept so the next tap
          // doesn't re-pay the search.
          matchedUnavailable.add(src);
          return;
        }
        results[src] = sources;
      } catch (e) {
        // Throw/timeout: classifica em vez de sumir — o diálogo mostra
        // "falhou, tente de novo" em vez de silêncio.
        errored.add(src);
        debugPrint(
            '[Repo] resolve ep $episodeNumber on $src failed: $e');
      } finally {
        done.add(src);
        onUpdate?.call(snapshot());
        checkGate();
        maybeCache();
      }
    }

    final futures = adapters.map(resolve).toList();

    if (useGate) {
      await gate!.future.timeout(partialGateDeadline, onTimeout: () {});
      return snapshot();
    }
    await Future.wait(futures);
    return snapshot();
  }
}