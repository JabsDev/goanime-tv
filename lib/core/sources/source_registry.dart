import 'package:flutter/foundation.dart';
import '../../data/models/anime.dart';
import '../scraper/scraper_result.dart';
import '../sources/anime_source_adapter.dart';
import '../sources/anime_fire_adapter.dart';
import '../sources/all_anime_adapter.dart';
import '../sources/goyabu_adapter.dart';
import '../sources/dooplay_adapter.dart';
import '../sources/animeplayer_adapter.dart';
import '../sources/animesonline_adapter.dart';

/// Holds the available source adapters and provides lookups by [AnimeSource].
class SourceRegistry {
  SourceRegistry._();

  // Ordered by PT-BR priority (AnimeFire, Goyabu, DooPlay), then AnimesOnline
  // cluster (direct CDN mp4), then AnimePlayer, then AllAnime.
  // AniList is metadata-only and is intentionally absent: it never participates
  // in search/video fan-out or fallback.
  static final List<AnimeSourceAdapter> _adapters = [
    AnimeFireAdapter(),
    GoyabuAdapter(),
    DooPlayAdapter(source: AnimeSource.dooPlay),
    AnimesOnlineAdapter(source: AnimeSource.animesOnlineCloud),
    AnimesOnlineAdapter(source: AnimeSource.animesDrive),
    AnimesOnlineAdapter(source: AnimeSource.animeQ),
    AnimesOnlineAdapter(source: AnimeSource.animePlay),
    DooPlayAdapter(source: AnimeSource.animesOnlineHdk),
    DooPlayAdapter(source: AnimeSource.animesOrion),
    DooPlayAdapter(source: AnimeSource.animesHd),
    AnimePlayerAdapter(),
    AllAnimeAdapter(),
  ];

  static List<AnimeSourceAdapter> get adapters => _adapters;

  static List<AnimeSource> get fallbackOrder {
    return [
      AnimeSource.animeFire,
      AnimeSource.goyabu,
      AnimeSource.dooPlay,
      AnimeSource.animesOnlineCloud,
      AnimeSource.animesDrive,
      AnimeSource.animeQ,
      AnimeSource.animePlay,
      AnimeSource.animesOnlineHdk,
      AnimeSource.animesOrion,
      AnimeSource.animesHd,
      AnimeSource.animePlayer,
    ];
  }

  static int getPriority(AnimeSource source) {
    switch (source) {
      case AnimeSource.animeFire:
        return 0;
      case AnimeSource.goyabu:
        return 1;
      case AnimeSource.dooPlay:
        return 2;
      case AnimeSource.animesOnlineCloud:
        return 3;
      case AnimeSource.animesDrive:
        return 4;
      case AnimeSource.animeQ:
        return 5;
      case AnimeSource.animePlay:
        return 6;
      case AnimeSource.animesOnlineHdk:
        return 7;
      case AnimeSource.animesOrion:
        return 8;
      case AnimeSource.animesHd:
        return 9;
      case AnimeSource.animePlayer:
        return 10;
      case AnimeSource.allAnime:
        return 11;
      case AnimeSource.betterAnime:
        return 12;
      case AnimeSource.animesRoll:
        return 13;
      case AnimeSource.anilist:
        return 14;
    }
  }

  static AnimeSourceAdapter forSource(AnimeSource source) {
    return _adapters.firstWhere(
      (a) => source == AnimeSource.animeFire && a is AnimeFireAdapter ||
             source == AnimeSource.goyabu && a is GoyabuAdapter ||
             source == AnimeSource.animePlayer && a is AnimePlayerAdapter ||
             source == AnimeSource.allAnime && a is AllAnimeAdapter ||
             a is DooPlayAdapter && a.source == source ||
             a is AnimesOnlineAdapter && a.source == source,
      orElse: () => _adapters.first,
    );
  }

  /// Searches for an anime using multiple sources in fallback order
  static Future<List<ScraperResult<List<Anime>>>> searchWithFallbacks(
    String query, {
    List<AnimeSource>? preferredSources,
  }) async {
    final results = <ScraperResult<List<Anime>>>[];
    final sources = preferredSources ?? fallbackOrder;

    for (final source in sources) {
      try {
        final adapter = forSource(source);
        final result = await adapter.search(query);
        results.add(result);
      } catch (e) {
        debugPrint('[SourceRegistry] Failed to search source $source: $e');
        results.add(ScraperResult.failure(UnknownError(
          message: 'Failed to search source $source: $e',
          source: source,
        )));
      }
    }

    return results;
  }
}
