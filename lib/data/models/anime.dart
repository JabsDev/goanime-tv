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
  });

  String get imageUrl => fallbackImageUrl ?? '';

  String get sourceName {
    switch (source) {
      case AnimeSource.animeFire:
        return 'AnimeFire';
      case AnimeSource.allAnime:
        return 'AllAnime';
      case AnimeSource.superFlix:
        return 'SuperFlix';
      case AnimeSource.goyabu:
        return 'Goyabu';
    }
  }
}

enum AnimeSource { animeFire, allAnime, superFlix, goyabu }

extension AnimeSourcePriority on AnimeSource {
  /// Whether this is a PT-BR source.
  bool get isPtBr =>
      this == AnimeSource.animeFire ||
      this == AnimeSource.goyabu ||
      this == AnimeSource.superFlix;

  /// Ordering priority for display/selection: lower = higher priority.
  /// PT-BR sources with reliable playback come first; AllAnime (EN, currently
  /// CAPTCHA-gated for streams) comes last.
  int get priority {
    switch (this) {
      case AnimeSource.animeFire:
        return 0;
      case AnimeSource.goyabu:
        return 1;
      case AnimeSource.superFlix:
        return 2;
      case AnimeSource.allAnime:
        return 3;
    }
  }
}
