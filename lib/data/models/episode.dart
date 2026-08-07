import 'anime.dart';

/// A canonical catalog episode (the grid shown to the user). Built exclusively
/// by the catalog (AniList): it carries no stream `url`, no `source` and no
/// `owner`, so the episode list never depends on a selected provider.
class CatalogEpisode {
  final int number;
  final String? title;
  final String? thumbnail;
  final String? description;

  const CatalogEpisode({
    required this.number,
    this.title,
    this.thumbnail,
    this.description,
  });
}

/// Internal episode used by the adapters to resolve a stream. Kept restricted
/// to provider internals: `url` is the provider's episode page and `source`/
/// `owner` carry the context needed to fetch its video.
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
