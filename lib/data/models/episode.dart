import 'anime.dart';

/// A canonical catalog episode (the grid shown to the user). Built exclusively
/// by the catalog (AniList): it carries no stream `url`, no `source` and no
/// `owner`, so the episode list never depends on a selected provider.
class CatalogEpisode {
  final int number;
  final String? title;
  final String? thumbnail;
  final String? description;

  /// Season badge for provider-fallback grids (AniList down): "T4" when the
  /// row came from a combined provider page whose episodes carry an
  /// unambiguous season (AnimeFire absolute numbers). Null on healthy
  /// AniList grids (relative 1..N needs no badge) and whenever the season
  /// is ambiguous — the badge only ever states provider-grounded truth.
  final String? seasonLabel;

  const CatalogEpisode({
    required this.number,
    this.title,
    this.thumbnail,
    this.description,
    this.seasonLabel,
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

  /// Season number as reported by the provider (AnimeFire numbers episodes
  /// per season; `number` carries the absolute number mapped via
  /// `seasons[].first_episode_number`). Null when the provider has no
  /// season concept — matching then falls back to `number` only.
  final int? season;

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
    this.season,
    this.source,
    this.owner,
  });
}

class VideoSource {
  final String url;
  final String quality;
  final Map<String, String> headers;

  /// Desired DASH Representation height (e.g. 720). Null = adaptive manifest.
  /// Set by providers whose single manifest carries every quality (AnimeFire);
  /// the player resolves it through the local MPD proxy. Ignored by direct
  /// mp4/hls sources.
  final int? dashHeight;

  /// Audio track as reported by the provider ("dublado"/"legendado" on
  /// AnimeFire). Null when the provider has no audio concept — the UI then
  /// skips the audio step and shows qualities directly.
  final String? audio;

  VideoSource({
    required this.url,
    required this.quality,
    this.headers = const {},
    this.dashHeight,
    this.audio,
  });
}
