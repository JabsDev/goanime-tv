class Anime {
  String name;
  String url;
  AnimeSource source;
  String? allAnimeId;
  String? goyabuUrl;
  String? fallbackImageUrl;
  String? bannerImage;
  String? description;
  int? episodes;
  String? status;
  double? averageScore;
  List<String> genres;
  int? anilistId;
  int? idMal;
  int? duration;

  /// AniList `isAdult` flag — canonical NSFW signal used by [NsfwFilter].
  bool? isAdult;

  /// English title (from AniList), used as fallback when the primary [name]
  /// (typically romaji) doesn't match a scraping source's catalog.
  String? englishName;

  Anime({
    required this.name,
    required this.url,
    this.source = AnimeSource.animeFire,
    this.allAnimeId,
    this.goyabuUrl,
    this.fallbackImageUrl,
    this.bannerImage,
    this.description,
    this.episodes,
    this.status,
    this.averageScore,
    this.genres = const [],
    this.englishName,
    this.anilistId,
    this.idMal,
    this.duration,
    this.isAdult,
  });

  String get imageUrl => fallbackImageUrl ?? '';

  String get sourceName {
    switch (source) {
      case AnimeSource.animeFire:
        return 'AnimeFire';
      case AnimeSource.anilist:
        return 'AniList';
      case AnimeSource.allAnime:
        return 'AllAnime';
      case AnimeSource.goyabu:
        return 'Goyabu';
      case AnimeSource.betterAnime:
        return 'BetterAnime';
      case AnimeSource.animesRoll:
        return 'AnimesROLL';
      case AnimeSource.dooPlay:
        return 'DooPlay';
      case AnimeSource.animePlayer:
        return 'Anime Player';
      case AnimeSource.animesOnlineCloud:
        return 'Animes Online';
      case AnimeSource.animesDrive:
        return 'Animes Drive';
      case AnimeSource.animeQ:
        return 'AnimeQ';
      case AnimeSource.animePlay:
        return 'Anime Play';
      case AnimeSource.animesOnlineHdk:
        return 'Animes Online HDK';
      case AnimeSource.animesOrion:
        return 'Animes Orion';
      case AnimeSource.animesHd:
        return 'AnimesHD';
    }
  }
}

enum AnimeSource {
  animeFire,
  allAnime,
  goyabu,
  betterAnime,
  animesRoll,
  dooPlay,
  animePlayer,
  anilist,
  animesOnlineCloud,
  animesDrive,
  animeQ,
  animePlay,
  animesOnlineHdk,
  animesOrion,
  animesHd,
}

extension AnimeSourcePriority on AnimeSource {
  /// Whether this is a PT-BR source. AniList is a metadata provider (like
  /// IMDB), not a stream source, so it doesn't participate in PT-BR ranking.
  bool get isPtBr =>
      this == AnimeSource.animeFire ||
      this == AnimeSource.goyabu ||
      this == AnimeSource.betterAnime ||
      this == AnimeSource.animesRoll ||
      this == AnimeSource.dooPlay ||
      this == AnimeSource.animePlayer ||
      this == AnimeSource.animesOnlineCloud ||
      this == AnimeSource.animesDrive ||
      this == AnimeSource.animeQ ||
      this == AnimeSource.animePlay ||
      this == AnimeSource.animesOnlineHdk ||
      this == AnimeSource.animesOrion ||
      this == AnimeSource.animesHd;

  /// Ordering priority for display/selection: lower = higher priority.
  /// PT-BR sources with reliable playback come first; AllAnime (EN, currently
  /// CAPTCHA-gated for streams) comes last; AniList is metadata-only.
  int get priority {
    switch (this) {
      case AnimeSource.animeFire:
        return 0;
      case AnimeSource.anilist:
        return 1;
      case AnimeSource.goyabu:
        return 2;
      case AnimeSource.betterAnime:
        return 3;
      case AnimeSource.animesRoll:
        return 4;
      case AnimeSource.dooPlay:
        return 5;
      case AnimeSource.animesOnlineCloud:
        return 6;
      case AnimeSource.animesDrive:
        return 7;
      case AnimeSource.animeQ:
        return 8;
      case AnimeSource.animePlay:
        return 9;
      case AnimeSource.animesOnlineHdk:
        return 10;
      case AnimeSource.animesOrion:
        return 11;
      case AnimeSource.animesHd:
        return 12;
      case AnimeSource.animePlayer:
        return 13;
      case AnimeSource.allAnime:
        return 14;
    }
  }
}
