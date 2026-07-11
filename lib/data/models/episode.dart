import 'anime.dart';

class Episode {
  final String number;
  final String url;
  final String? thumbnail;
  final String? title;
  final String? description;

  /// The provider this episode was listed from. When set, video resolution
  /// dispatches to this source instead of the parent anime's source (episodes
  /// can be merged from multiple providers).
  AnimeSource? source;

  /// The anime context (carrying provider ids like allAnimeId / tmdbId / url)
  /// required to resolve this episode's stream on [source].
  Anime? owner;

  Episode({
    required this.number,
    required this.url,
    this.thumbnail,
    this.title,
    this.description,
    this.source,
    this.owner,
  });
}

class VideoSource {
  final String url;
  final String quality;
  final Map<String, String> headers;

  VideoSource({
    required this.url,
    required this.quality,
    this.headers = const {},
  });
}

class EpisodesResult {
  final List<Episode> episodes;
  final Map<String, List<Episode>> sourceOptions;

  EpisodesResult(this.episodes, this.sourceOptions);
}
