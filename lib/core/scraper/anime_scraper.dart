import 'package:flutter/foundation.dart';
import '../anilist/anilist_service.dart';
import '../cache/app_caches.dart';
import '../sources/source_registry.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import 'scraper_result.dart';

/// Orchestration layer that aggregates results from every [AnimeSourceAdapter],
/// enriches them with AniList metadata (cached + deduped) and merges episode
/// lists from multiple providers.
///
/// All public methods are memoized via [AppCaches] so navigating between
/// screens never re-triggers the same network work.
class AnimeScraper {
  static Future<List<Anime>> searchAnime(String animeName) async {
    final cacheKey = animeName.trim().toLowerCase();
    final cached = AppCaches.search.get<List<Anime>>(cacheKey);
    if (cached != null) return cached;

    try {
      debugPrint('[AnimeScraper] Searching: $animeName');

      // Per-future error isolation: one adapter's unhandled exception does not
      // kill other adapter futures via Future.wait (Pitfall 1).
      final futures = SourceRegistry.adapters.map((a) async {
        try {
          return await a.search(animeName);
        } catch (e) {
          debugPrint('[AnimeScraper] Unhandled exception from ${a.source}: $e');
          return ScraperResult<List<Anime>>.failure(UnknownError(
            message: 'Unhandled: $e',
            source: a.source,
            operationDuration: Duration.zero,
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
          case AnimeSource.superFlix:
            return a.superFlixTmdbId != null;
          case AnimeSource.animeFire:
          case AnimeSource.goyabu:
            return a.url.isNotEmpty;
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

  static Future<EpisodesResult> getEpisodes(Anime anime) async {
    final cacheKey =
        '${anime.source.name}:${anime.url}:${anime.allAnimeId ?? ''}:${anime.superFlixTmdbId ?? ''}';
    final cached = AppCaches.episodes.get<EpisodesResult>(cacheKey);
    if (cached != null) return cached;

    try {
      final animeFire = SourceRegistry.forSource(AnimeSource.animeFire);
      final allAnime = SourceRegistry.forSource(AnimeSource.allAnime);
      final superFlix = SourceRegistry.forSource(AnimeSource.superFlix);
      final goyabu = SourceRegistry.forSource(AnimeSource.goyabu);

      // Resolve the anime context (with provider ids) for each source, then
      // fetch its episodes. Each fetched episode is tagged with its source +
      // owner so stream resolution can dispatch to the right provider later.
      final fetchers = <String, Future<ScraperResult<EpisodesResult>>>{};
      final owners = <String, Anime>{};
      final sourceOf = <String, AnimeSource>{};

      void register(String name, AnimeSource src, Anime owner,
          Future<ScraperResult<EpisodesResult>> future) {
        fetchers[name] = future;
        owners[name] = owner;
        sourceOf[name] = src;
      }

      // 1. Use the anime's own source when it carries the required identifier.
      Anime? afOwner;
      Anime? aaOwner;
      Anime? sfOwner;
      Anime? gyOwner;
      if (anime.source == AnimeSource.allAnime && anime.allAnimeId != null) {
        aaOwner = anime;
      } else if (anime.source == AnimeSource.superFlix &&
          anime.superFlixTmdbId != null) {
        sfOwner = anime;
      } else if (anime.source == AnimeSource.animeFire && anime.url.isNotEmpty) {
        afOwner = anime;
      } else if (anime.source == AnimeSource.goyabu && anime.url.isNotEmpty) {
        gyOwner = anime;
      }

      // 2 & 3. Fall back to searching the other providers by name.
      afOwner ??= await _findBySource(anime.name, AnimeSource.animeFire);
      aaOwner ??= await _findBySource(anime.name, AnimeSource.allAnime);
      sfOwner ??= await _findBySource(anime.name, AnimeSource.superFlix);
      gyOwner ??= await _findBySource(anime.name, AnimeSource.goyabu);

      // Register in PT-BR priority order so the default episode list and the
      // source dropdown prefer working PT-BR providers.
      if (afOwner != null) {
        register('AnimeFire', AnimeSource.animeFire, afOwner,
            animeFire.getEpisodes(afOwner));
      }
      if (gyOwner != null) {
        register('Goyabu', AnimeSource.goyabu, gyOwner,
            goyabu.getEpisodes(gyOwner));
      }
      if (sfOwner != null) {
        register('SuperFlix', AnimeSource.superFlix, sfOwner,
            superFlix.getEpisodes(sfOwner));
      }
      if (aaOwner != null) {
        register('AllAnime', AnimeSource.allAnime, aaOwner,
            allAnime.getEpisodes(aaOwner));
      }

      if (fetchers.isEmpty) return EpisodesResult([], {});

      final sourceKeys = fetchers.keys.toList();

      // Per-future error isolation for episode fetchers
      final futures = fetchers.values.map((f) async {
        try {
          return await f;
        } catch (e) {
          debugPrint('[AnimeScraper] Episode fetch error: $e');
          return ScraperResult<EpisodesResult>.failure(UnknownError(
            message: 'Unhandled episode fetch: $e',
            source: AnimeSource.animeFire, // approximate; exact source from context
            operationDuration: Duration.zero,
            originalError: e,
          ));
        }
      });
      final results = await Future.wait(futures);

      List<Episode> tag(String key, List<Episode> eps) {
        final src = sourceOf[key]!;
        final owner = owners[key]!;
        for (final e in eps) {
          e.source = src;
          e.owner = owner;
        }
        return eps;
      }

      final grouped = <String, List<Episode>>{};
      var firstEpisodes = <Episode>[];
      String? firstName;

      for (var i = 0; i < results.length; i++) {
        final result = results[i];
        final key = sourceKeys[i];
        switch (result) {
          case Success(data: final episodesResult):
            if (episodesResult.sourceOptions.isNotEmpty) {
              for (final entry in episodesResult.sourceOptions.entries) {
                grouped['$key (${entry.key})'] = tag(key, entry.value);
              }
            } else if (episodesResult.episodes.isNotEmpty) {
              grouped[key] = tag(key, episodesResult.episodes);
            }
            if (firstName == null && episodesResult.episodes.isNotEmpty) {
              firstEpisodes = tag(key, episodesResult.episodes);
              firstName = key;
            }
          case Failure(error: final err):
            debugPrint('[AnimeScraper] $key episodes failed: ${err.message}');
          case Loading():
            break;
        }
      }

      EpisodesResult result;
      if (grouped.length > 1) {
        result = EpisodesResult(firstEpisodes, grouped);
      } else if (grouped.length == 1) {
        final entry = grouped.entries.first;
        result = EpisodesResult(entry.value, {});
      } else {
        result = EpisodesResult(firstEpisodes, {});
      }

      AppCaches.episodes.set(cacheKey, result);
      return result;
    } catch (e) {
      // Safety net — typed errors should be caught above
      debugPrint('[AnimeScraper] Get episodes error: $e');
      return EpisodesResult([], {});
    }
  }

  static Future<Anime?> _findBySource(String name, AnimeSource source) async {
    try {
      final adapter = SourceRegistry.forSource(source);
      final result = await adapter.search(name);
      switch (result) {
        case Success(data: final results):
          if (results.isEmpty) return null;
          bool valid(Anime a) {
            switch (source) {
              case AnimeSource.allAnime:
                return a.allAnimeId != null;
              case AnimeSource.superFlix:
                return a.superFlixTmdbId != null;
              case AnimeSource.animeFire:
              case AnimeSource.goyabu:
                return a.url.isNotEmpty;
            }
          }

          final candidates = results.where(valid).toList();
          if (candidates.isEmpty) return null;
          return _bestMatch(name, candidates, source);
        case Failure(error: final err):
          debugPrint('[AnimeScraper] _findBySource($source) error: ${err.message}');
          return null;
        case Loading():
          return null;
      }
    } catch (e) {
      // Safety net — typed errors should be caught above
      debugPrint('[AnimeScraper] _findBySource($source) error: $e');
      return null;
    }
  }

  /// Picks the candidate whose title best matches [query]. Prefers exact/prefix
  /// matches and, for AnimeFire, the full-series page (`todos-os-episodios`)
  /// over movies/spin-offs so catalog titles resolve to the main series.
  static Anime _bestMatch(
      String query, List<Anime> candidates, AnimeSource source) {
    final q = _normalize(query);
    int score(Anime a) {
      final t = _normalize(a.name);
      var s = 0;
      if (t == q) {
        s += 100;
      } else if (t.startsWith(q) || q.startsWith(t)) {
        s += 60;
      } else if (t.contains(q) || q.contains(t)) {
        s += 40;
      } else {
        // token overlap
        final qt = q.split(' ').toSet();
        final tt = t.split(' ').toSet();
        final overlap = qt.intersection(tt).length;
        s += overlap * 8;
      }
      // Shorter titles closer to the query are usually the main entry.
      final diff = (t.length - q.length).abs();
      s -= diff ~/ 8;
      if (source == AnimeSource.animeFire &&
          a.url.contains('todos-os-episodios')) {
        s += 15;
      }
      // Penalize movies/spin-offs/side-stories when the query doesn't ask for
      // them, so "One Piece" prefers the series over "One Piece Film: Red".
      const sideTokens = ['film', 'movie', 'ova', 'special', 'gaiden', 'recap'];
      for (final tok in sideTokens) {
        if (t.contains(tok) && !q.contains(tok)) s -= 25;
      }
      return s;
    }

    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates.first;
  }

  static String _normalize(String s) {
    var t = s.toLowerCase();
    const from = 'áàãâäéèêëíìîïóòõôöúùûüç';
    const to = 'aaaaaeeeeiiiiooooouuuuc';
    for (var i = 0; i < from.length; i++) {
      t = t.replaceAll(from[i], to[i]);
    }
    t = t.replaceAll(RegExp(r'\b(dublado|legendado|dub|sub|todos os episodios)\b'), ' ');
    t = t.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }
}
