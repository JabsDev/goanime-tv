import 'package:flutter/foundation.dart';
import '../anilist/anilist_service.dart';
import '../cache/app_caches.dart';
import '../sources/anime_source_adapter.dart';
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

    final allAnimes = await _search(query);

    // Fase 1: busca com variantes de query. Fan-out vazio não é sinal de que a
    // série não existe — só de que nenhum provedor casou com aquele título.
    // Pede os títulos alternativos do AniList (romaji/english/native) e tenta
    // cada um; pára na primeira variante que retornar resultados.
    if (allAnimes.isEmpty) {
      final variants = await AniListService.getTitleVariants(query);
      for (final variant in variants) {
        final extra = await _search(variant);
        for (final a in extra) {
          if (!allAnimes.any((e) => titleIdentityKey(e) == titleIdentityKey(a))) {
            allAnimes.add(a);
          }
        }
        if (allAnimes.isNotEmpty) break;
      }
    }

    // Passada A: collapse by normalized title — dublado/legendado variants,
    // " – Todos os Episódios", badge "N/A A14" and cross-source copies of the
    // same show. Representative = url válida → menor source.priority → menor
    // índice no array (C5/C8, mesma ordem do sort final).
    final survivors = dedupeByTitle(allAnimes);

    // Cache-hit no-op na maioria dos casos — `_search` já enriqueceu o lote;
    // cobre o cenário de merge de variantes vindas de outro cache de busca.
    await AniListService.enrichBatch(survivors);

    // Passada B: merge survivors that share a resolved anilistId ("Naruto
    // Shippuden" vs "Naruto Shippuuden"). Best-effort — id null (rate-limit)
    // means this pass is skipped for that card (C7).
    final deduped = mergeByAnilistId(survivors);

    // Prioritize PT-BR sources (stable sort keeps per-source order).
    deduped.sort((a, b) => a.source.priority.compareTo(b.source.priority));

    AppCaches.search.set(cacheKey, deduped);
    return deduped;
  }

  /// Chave de identidade por título (passada A). Função pura e offline.
  ///
  /// `normalize(cleanTitle(name))` dobra acentos, remove
  /// dublado/legendado/dub/sub/"todos os episodios" e pontuação (inclui o
  /// travessão " – "). Corrige o badge "N/A A14" que `cleanTitle` não remove
  /// (nota alfanumérica antes de A14 — "One Piece Film: Red N/A A14"); o
  /// sufixo normalizado vira "n a a14". Guarda C12: nunca retorna ''.
  static String titleIdentityKey(Anime a) {
    var t = AnimeSourceAdapter.normalize(TextUtils.cleanTitle(a.name));

    // C4: strip do badge de faixa etária com nota ausente no FIM do título.
    t = t.replaceAll(RegExp(r'\bn\s*a\s*a?\s*\d+\s*$'), '').trim();

    // C12: nome só com pontuação/símbolos → chave vazia fundiria tudo.
    if (t.isEmpty) t = a.name.trim().toLowerCase();
    if (t.isEmpty) t = a.url;
    return t;
  }

  /// Chave para a passada B (fusão por id AniList). Null quando o enrich
  /// falhou (ex.: rate-limit) — o card fica só na passada A.
  static int? anilistIdentityKey(Anime a) => a.anilistId;

  static List<Anime> dedupeByTitle(List<Anime> animes) {
    final groups = <String, List<Anime>>{};
    for (final a in animes) {
      groups.putIfAbsent(titleIdentityKey(a), () => []).add(a);
      // ponytail: mapa em memória compartilhado; subir para um índice
      // persistente por chave se o custo de resolver o grupo crescer.
    }
    return [for (final g in groups.values) _pickRepresentative(g)];
  }

  static List<Anime> mergeByAnilistId(List<Anime> animes) {
    final groups = <int, List<Anime>>{};
    for (final a in animes) {
      final id = a.anilistId;
      if (id != null) groups.putIfAbsent(id, () => []).add(a);
    }
    final result = <Anime>[];
    final used = <Anime>{};
    for (final a in animes) {
      if (used.contains(a)) continue;
      final group = a.anilistId == null ? null : groups[a.anilistId];
      if (group == null || group.length == 1) {
        result.add(a);
        used.add(a);
        continue;
      }
      final rep = _pickRepresentative(group);
      for (final d in group) {
        used.add(d);
        if (d != rep) _propagate(rep, d);
      }
      result.add(rep);
    }
    return result;
  }

  /// Representante do grupo: url válida → menor `source.priority` (ordem de
  /// `anime.dart`, não `SourceRegistry.getPriority`) → menor índice do array
  /// (primeiro encontrado vence empates).
  static Anime _pickRepresentative(List<Anime> group) {
    var best = group.first;
    for (final a in group.skip(1)) {
      final bestHasUrl = best.url.isNotEmpty;
      final aHasUrl = a.url.isNotEmpty;
      if (!bestHasUrl && aHasUrl) {
        best = a;
      } else if (bestHasUrl && aHasUrl && a.source.priority < best.source.priority) {
        best = a;
      }
    }
    return best;
  }

  /// Propagação de metadados (C6): `??=` nunca sobrescreve valor bom com null;
  /// `genres` trata lista vazia como "faltando". Nome exibido permanece o do
  /// representante (favoritos/progresso são chaveados por `anime.name`).
  static void _propagate(Anime s, Anime d) {
    s.anilistId ??= d.anilistId;
    s.englishName ??= d.englishName;
    s.bannerImage ??= d.bannerImage;
    s.description ??= d.description;
    s.fallbackImageUrl ??= d.fallbackImageUrl;
    s.episodes ??= d.episodes;
    s.status ??= d.status;
    s.averageScore ??= d.averageScore;
    if (d.genres.isNotEmpty) s.genres = d.genres;
  }

  /// Per-query fan-out over every implemented provider. Results are cached per
  /// cleaned query, so variant retries (Fase 1) stay one-call-per-provider.
  static Future<List<Anime>> _search(String query) async {
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
          case AnimeSource.animesOnlineCloud:
          case AnimeSource.animesDrive:
          case AnimeSource.animeQ:
          case AnimeSource.animePlay:
            return a.url.isNotEmpty;
          case AnimeSource.anilist:
            return false; // metadata provider, no stream URL
        }
      }
      allAnimes.removeWhere((a) => !hasValidId(a));

      // Enrichment is cached + deduped per cleaned title inside AniListService,
      // so the same show appearing in multiple sources is only fetched once.
      // Batch with a pool of 6 in-flight calls (rate-limit friendly — Fase 5).
      await AniListService.enrichBatch(allAnimes);

      AppCaches.search.set(cacheKey, allAnimes);
      return allAnimes;
    } catch (e) {
      // Safety net — typed errors should be caught above
      debugPrint('[AnimeScraper] Search error: $e');
      return [];
    }
  }
}
