import '../../data/models/anime.dart';
import 'anime_source_adapter.dart';
import 'anime_fire_adapter.dart';
import 'all_anime_adapter.dart';
import 'super_flix_adapter.dart';
import 'goyabu_adapter.dart';
import 'dooplay_adapter.dart';
import 'animes_digital_adapter.dart';

/// Factory for creating [AnimeSourceAdapter] instances.
///
/// Each adapter implements the [AnimeSourceAdapter] interface and knows how to
/// search, list episodes, and extract video sources for a specific anime provider.
class AnimeSourceAdapterFactory {
  AnimeSourceAdapterFactory._();

  /// Creates an adapter for the specified [AnimeSource].
  static AnimeSourceAdapter create(AnimeSource source) {
    switch (source) {
      case AnimeSource.animeFire:
        return AnimeFireAdapter();
      case AnimeSource.allAnime:
        return AllAnimeAdapter();
      case AnimeSource.superFlix:
        return SuperFlixAdapter();
      case AnimeSource.goyabu:
        return GoyabuAdapter();
      case AnimeSource.betterAnime:
        return DooPlayAdapter(source: AnimeSource.betterAnime);
      case AnimeSource.animesRoll:
        return DooPlayAdapter(source: AnimeSource.animesRoll);
      case AnimeSource.animesDigital:
        return AnimesDigitalAdapter();
      case AnimeSource.dooPlay:
        return DooPlayAdapter(source: AnimeSource.dooPlay);
      default:
        return AnimeFireAdapter();
    }
  }
}
