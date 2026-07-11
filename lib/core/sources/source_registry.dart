import '../../data/models/anime.dart';
import 'anime_source_adapter.dart';
import 'anime_fire_adapter.dart';
import 'all_anime_adapter.dart';
import 'super_flix_adapter.dart';
import 'goyabu_adapter.dart';

/// Holds the available source adapters and provides lookups by [AnimeSource].
class SourceRegistry {
  SourceRegistry._();

  // Ordered by PT-BR priority (AnimeFire, Goyabu, SuperFlix), then AllAnime.
  static final List<AnimeSourceAdapter> _adapters = [
    AnimeFireAdapter(),
    GoyabuAdapter(),
    const SuperFlixAdapter(),
    const AllAnimeAdapter(),
  ];

  static List<AnimeSourceAdapter> get adapters => _adapters;

  static AnimeSourceAdapter forSource(AnimeSource source) {
    return _adapters.firstWhere(
      (a) => a.source == source,
      orElse: () => _adapters.first,
    );
  }
}
