class AniListUser {
  final int id;
  final String name;
  final String? avatar;

  AniListUser({required this.id, required this.name, this.avatar});

  factory AniListUser.fromJson(Map<String, dynamic> json) {
    return AniListUser(
      id: json['id'] as int,
      name: json['name'] as String,
      avatar: json['avatar'] is Map
          ? (json['avatar'] as Map)['large']?.toString()
          : json['avatar']?.toString(),
    );
  }
}

class AniListMedia {
  final int id;
  final int? idMal;
  final int? duration;
  final String title;
  final String? coverImage;
  final String? coverImageExtra;
  final String? bannerImage;
  final int? episodes;
  final String? format;
  final String? status;
  final bool? isAdult;
  final List<String> genres;

  AniListMedia({
    required this.id,
    this.idMal,
    this.duration,
    required this.title,
    this.coverImage,
    this.coverImageExtra,
    this.bannerImage,
    this.episodes,
    this.format,
    this.status,
    this.isAdult,
    this.genres = const [],
  });

  factory AniListMedia.fromJson(Map<String, dynamic> json) {
    final titleObj = json['title'] as Map? ?? {};
    final cover = json['coverImage'] as Map?;
    return AniListMedia(
      id: json['id'] as int,
      idMal: json['idMal'] as int?,
      duration: json['duration'] as int?,
      title: titleObj['romaji']?.toString() ??
             titleObj['english']?.toString() ??
             titleObj['native']?.toString() ??
             'Unknown',
      coverImage: cover?['large']?.toString(),
      coverImageExtra: cover?['extraLarge']?.toString(),
      bannerImage: json['bannerImage']?.toString(),
      episodes: json['episodes'] as int?,
      format: json['format']?.toString(),
      status: json['status']?.toString(),
      isAdult: json['isAdult'] as bool?,
      genres: (json['genres'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }
}

class AniListEntry {
  final AniListMedia media;
  final int? progress;
  final String? status;
  final int? nextEpisode;
  final int? timeUntilAiring;
  // ponytail: MediaList.updatedAt (Unix seconds) — "When the entry data was
  // last updated". Usado para ordenar "Continue assistindo" por último
  // assistido no client. Vem do nível do entry no schema AniList.
  final int? updatedAt;

  AniListEntry({
    required this.media,
    this.progress,
    this.status,
    this.nextEpisode,
    this.timeUntilAiring,
    this.updatedAt,
  });

  // ponytail: nextAiringEpisode pertence a MediaList.media no schema AniList,
// não ao entry. Lendo do mapa aninhado para casar com a query GraphQL.
factory AniListEntry.fromJson(Map<String, dynamic> json) {
    final media = (json['media'] as Map?)?.cast<String, dynamic>() ?? const {};
    final next = media['nextAiringEpisode'] as Map?;
    return AniListEntry(
      media: AniListMedia.fromJson(media),
      progress: json['progress'] as int?,
      status: json['status']?.toString(),
      nextEpisode: next?['episode'] as int?,
      timeUntilAiring: next?['timeUntilAiring'] as int?,
      updatedAt: json['updatedAt'] as int?,
    );
  }
}

class AniListCoverImage {
  final String best;
  final String large;
  final String medium;
  final String extraLarge;

  AniListCoverImage({
    required this.best,
    this.large = '',
    this.medium = '',
    this.extraLarge = '',
  });

  factory AniListCoverImage.fromJson(Map<String, dynamic> json) {
    return AniListCoverImage(
      best: json['extraLarge']?.toString() ??
            json['large']?.toString() ??
            json['medium']?.toString() ??
            '',
      large: json['large']?.toString() ?? '',
      medium: json['medium']?.toString() ?? '',
      extraLarge: json['extraLarge']?.toString() ?? '',
    );
  }
}

class AniListMediaDetail {
  final int id;
  final int? idMal;
  final int? duration;
  final String? englishName;
  final String? bannerImage;
  final String? description;
  final int? episodes;
  final int? nextAiringEpisodeNumber;
  final String? status;
  final double? averageScore;
  final List<String> genres;
  final bool? isAdult;
  final List<String> tags;
  final AniListCoverImage coverImage;

  AniListMediaDetail({
    required this.id,
    this.idMal,
    this.duration,
    this.englishName,
    this.bannerImage,
    this.description,
    this.episodes,
    this.nextAiringEpisodeNumber,
    this.status,
    this.averageScore,
    this.genres = const [],
    this.isAdult,
    this.tags = const [],
    required this.coverImage,
  });

  factory AniListMediaDetail.fromJson(Map<String, dynamic> json) {
    final title = json['title'] as Map? ?? {};
    final next = json['nextAiringEpisode'] as Map?;
    return AniListMediaDetail(
      id: json['id'] as int? ?? 0,
      idMal: json['idMal'] as int?,
      duration: json['duration'] as int?,
      englishName: title['english']?.toString(),
      bannerImage: json['bannerImage']?.toString(),
      description: json['description']?.toString(),
      episodes: json['episodes'] as int?,
      nextAiringEpisodeNumber: next?['episode'] as int?,
      status: json['status']?.toString(),
      averageScore: (json['averageScore'] as num?)?.toDouble(),
      genres: (json['genres'] as List?)?.map((e) => e.toString()).toList() ?? [],
      isAdult: json['isAdult'] as bool?,
      tags: (json['tags'] as List?)
              ?.map((e) => (e as Map)['name']?.toString() ?? '')
              .where((n) => n.isNotEmpty)
              .toList() ??
          const [],
      coverImage: AniListCoverImage.fromJson(
        json['coverImage'] as Map<String, dynamic>? ?? {},
      ),
    );
  }
}

class AniListGraphQLMediaData {
  final AniListMediaDetail media;

  AniListGraphQLMediaData({required this.media});

  factory AniListGraphQLMediaData.fromJson(Map<String, dynamic> json) {
    final mediaJson = json['Media'];
    if (mediaJson == null) {
      return AniListGraphQLMediaData(
        media: AniListMediaDetail.fromJson(<String, dynamic>{}),
      );
    }
    return AniListGraphQLMediaData(
      media: AniListMediaDetail.fromJson(mediaJson as Map<String, dynamic>),
    );
  }
}

class AniListGraphQLResponse {
  final AniListGraphQLMediaData data;

  AniListGraphQLResponse({required this.data});

  factory AniListGraphQLResponse.fromJson(Map<String, dynamic> json) {
    final dataJson = json['data'];
    return AniListGraphQLResponse(
      data: dataJson != null
          ? AniListGraphQLMediaData.fromJson(dataJson as Map<String, dynamic>)
          : AniListGraphQLMediaData.fromJson(<String, dynamic>{}),
    );
  }
}

class AniListGroup {
  final String name;
  final List<AniListEntry> entries;

  AniListGroup({required this.name, required this.entries});

  factory AniListGroup.fromJson(Map<String, dynamic> json) {
    final entriesJson = json['entries'] as List? ?? [];
    return AniListGroup(
      name: json['name']?.toString() ?? 'Unknown',
      entries: entriesJson
          .map((e) => AniListEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class AniListEpisode {
  final String number;
  final String? title;
  final String? description;
  final String? thumbnail;

  AniListEpisode({
    required this.number,
    this.title,
    this.description,
    this.thumbnail,
  });

  factory AniListEpisode.fromMap(Map<String, dynamic> map) {
    return AniListEpisode(
      number: map['episodeNumber']?.toString() ?? '',
      title: map['title']?.toString(),
      description: map['description']?.toString(),
      thumbnail: map['thumbnail']?.toString(),
    );
  }
}
