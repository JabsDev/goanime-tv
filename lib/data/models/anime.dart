class Anime {
  String name;
  String url;
  AnimeSource source;
  String? allAnimeId;
  String? superFlixTmdbId;
  String? goyabuUrl;
  String? fallbackImageUrl;
  String? bannerImage;
  String? description;
  int? episodes;
  String? status;
  double? averageScore;
  List<String> genres;
  int? anilistId;

  /// English title (from AniList), used as fallback when the primary [name]
  /// (typically romaji) doesn't match a scraping source's catalog.
  String? englishName;

  Anime({
    required this.name,
    required this.url,
    this.source = AnimeSource.animeFire,
    this.allAnimeId,
    this.superFlixTmdbId,
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
      case AnimeSource.superFlix:
        return 'SuperFlix';
      case AnimeSource.goyabu:
        return 'Goyabu';
      case AnimeSource.betterAnime:
        return 'BetterAnime';
      case AnimeSource.animesRoll:
        return 'AnimesROLL';
      case AnimeSource.anikyuu:
        return 'Anikyuu';
      case AnimeSource.anitube:
        return 'Anitube';
      case AnimeSource.dattebayo:
        return 'Dattebayo';
      case AnimeSource.animesDigital:
        return 'AnimesDigital';
      case AnimeSource.dooPlay:
        return 'DooPlay';
      case AnimeSource.animePlay:
        return 'Anime Play';
      case AnimeSource.animePlayer:
        return 'Anime Player';
      case AnimeSource.animeQ:
        return 'Anime Q';
      case AnimeSource.animeIto:
        return 'Anime Ito';
    }
  }
}

enum AnimeSource {
  animeFire,
  allAnime,
  superFlix,
  goyabu,
  betterAnime,
  animesRoll,
  anikyuu,
  anitube,
  dattebayo,
  animesDigital,
  dooPlay,
  animePlay,
  animePlayer,
  animeQ,
  animeIto,
  anilist,
}

extension AnimeSourcePriority on AnimeSource {
  /// Whether this is a PT-BR source.
  bool get isPtBr =>
      this == AnimeSource.animeFire ||
      this == AnimeSource.goyabu ||
      this == AnimeSource.superFlix ||
      this == AnimeSource.betterAnime ||
      this == AnimeSource.animesRoll ||
      this == AnimeSource.anikyuu ||
      this == AnimeSource.anitube ||
      this == AnimeSource.dattebayo ||
      this == AnimeSource.animesDigital ||
      this == AnimeSource.dooPlay ||
      this == AnimeSource.animePlay ||
      this == AnimeSource.animePlayer ||
      this == AnimeSource.animeQ ||
      this == AnimeSource.anilist;

  /// Ordering priority for display/selection: lower = higher priority.
  /// PT-BR sources with reliable playback come first; AllAnime (EN, currently
  /// CAPTCHA-gated for streams) comes last.
  int get priority {
    switch (this) {
      case AnimeSource.animeFire:
        return 0;
      case AnimeSource.anilist:
        return 1;
      case AnimeSource.goyabu:
        return 2;
      case AnimeSource.superFlix:
        return 3;
      case AnimeSource.betterAnime:
        return 4;
      case AnimeSource.animesRoll:
        return 5;
      case AnimeSource.anikyuu:
        return 6;
      case AnimeSource.anitube:
        return 7;
      case AnimeSource.dattebayo:
        return 8;
      case AnimeSource.animesDigital:
        return 9;
      case AnimeSource.dooPlay:
        return 10;
      case AnimeSource.allAnime:
        return 11;
      case AnimeSource.animePlay:
        return 12;
      case AnimeSource.animePlayer:
        return 12;
      case AnimeSource.animeQ:
        return 13;
      case AnimeSource.animeIto:
        return 14;
    }
  }
}
