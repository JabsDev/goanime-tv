import 'package:flutter/foundation.dart';
import '../../data/models/anime.dart';
import '../scraper/scraper_result.dart';
import '../sources/anime_source_adapter.dart';
import '../sources/anime_fire_adapter.dart';
import '../sources/anilist_adapter.dart';
import '../sources/all_anime_adapter.dart';
import '../sources/super_flix_adapter.dart';
import '../sources/goyabu_adapter.dart';
import '../sources/animes_digital_adapter.dart';
import '../sources/dooplay_adapter.dart';
import '../sources/anikyuu_adapter.dart';
import '../sources/animeito_adapter.dart';
import '../sources/animeplay_adapter.dart';
import '../sources/animeplayer_adapter.dart';
import '../sources/animeq_adapter.dart';

/// Holds the available source adapters and provides lookups by [AnimeSource].
class SourceRegistry {
  SourceRegistry._();

  // Ordered by PT-BR priority (AnimeFire, Goyabu, SuperFlix), then AllAnime.
  static final List<AnimeSourceAdapter> _adapters = [
    AnimeFireAdapter(),
    AniListAdapter(),
    GoyabuAdapter(),
    SuperFlixAdapter(),
    AnimesDigitalAdapter(),
    DooPlayAdapter(source: AnimeSource.dooPlay),
    AllAnimeAdapter(),
    AnikyuuAdapter(),
    AnimeitoAdapter(),
    AnimePlayAdapter(),
    AnimePlayerAdapter(),
    AnimeQAdapter(),
  ];

  static List<AnimeSourceAdapter> get adapters => _adapters;

  static List<AnimeSource> get fallbackOrder {
    return [
      AnimeSource.animeFire,
      AnimeSource.goyabu,
      AnimeSource.superFlix,
      AnimeSource.anikyuu,
      AnimeSource.animeIto,
      AnimeSource.animePlay,
      AnimeSource.animePlayer,
      AnimeSource.animeQ,
      AnimeSource.animesDigital,
      AnimeSource.dooPlay,
      AnimeSource.allAnime,
    ];
  }

  static int getPriority(AnimeSource source) {
    switch (source) {
      case AnimeSource.animeFire:
        return 0;
      case AnimeSource.goyabu:
        return 1;
      case AnimeSource.superFlix:
        return 2;
      case AnimeSource.anikyuu:
        return 3;
      case AnimeSource.animeIto:
        return 4;
      case AnimeSource.animePlay:
        return 5;
      case AnimeSource.animePlayer:
        return 6;
      case AnimeSource.animeQ:
        return 7;
      case AnimeSource.animesDigital:
        return 8;
      case AnimeSource.dooPlay:
        return 9;
      case AnimeSource.allAnime:
        return 10;
      default:
        return 11;
    }
  }

  static AnimeSourceAdapter forSource(AnimeSource source) {
    return _adapters.firstWhere(
      (a) => source == AnimeSource.animeFire && a is AnimeFireAdapter ||
             source == AnimeSource.goyabu && a is GoyabuAdapter ||
             source == AnimeSource.superFlix && a is SuperFlixAdapter ||
             source == AnimeSource.anikyuu && a is AnikyuuAdapter ||
             source == AnimeSource.animeIto && a is AnimeitoAdapter ||
             source == AnimeSource.animePlay && a is AnimePlayAdapter ||
             source == AnimeSource.animePlayer && a is AnimePlayerAdapter ||
             source == AnimeSource.animeQ && a is AnimeQAdapter ||
             source == AnimeSource.animesDigital && a is AnimesDigitalAdapter ||
             source == AnimeSource.dooPlay && a is DooPlayAdapter ||
             source == AnimeSource.allAnime && a is AllAnimeAdapter,
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
