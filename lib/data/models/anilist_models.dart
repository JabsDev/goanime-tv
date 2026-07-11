class AniListUser {
  final int id;
  final String name;
  final String? avatar;

  AniListUser({required this.id, required this.name, this.avatar});

  factory AniListUser.fromJson(Map<String, dynamic> json) {
    return AniListUser(
      id: json['id'] as int,
      name: json['name'] as String,
      avatar: (json['avatar'] as Map?)?['large']?.toString(),
    );
  }
}

class AniListMedia {
  final int id;
  final String title;
  final String? coverImage;
  final int? episodes;
  final String? format;

  AniListMedia({
    required this.id,
    required this.title,
    this.coverImage,
    this.episodes,
    this.format,
  });

  factory AniListMedia.fromJson(Map<String, dynamic> json) {
    final titleObj = json['title'] as Map? ?? {};
    return AniListMedia(
      id: json['id'] as int,
      title: titleObj['romaji']?.toString() ??
             titleObj['english']?.toString() ??
             titleObj['native']?.toString() ??
             'Unknown',
      coverImage: (json['coverImage'] as Map?)?['large']?.toString(),
      episodes: json['episodes'] as int?,
      format: json['format']?.toString(),
    );
  }
}

class AniListEntry {
  final AniListMedia media;

  AniListEntry({required this.media});

  factory AniListEntry.fromJson(Map<String, dynamic> json) {
    return AniListEntry(
      media: AniListMedia.fromJson(json['media'] as Map<String, dynamic>),
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
  final String? bannerImage;
  final String? description;
  final int? episodes;
  final String? status;
  final double? averageScore;
  final List<String> genres;
  final AniListCoverImage coverImage;

  AniListMediaDetail({
    required this.id,
    this.bannerImage,
    this.description,
    this.episodes,
    this.status,
    this.averageScore,
    this.genres = const [],
    required this.coverImage,
  });

  factory AniListMediaDetail.fromJson(Map<String, dynamic> json) {
    return AniListMediaDetail(
      id: json['id'] as int? ?? 0,
      bannerImage: json['bannerImage']?.toString(),
      description: json['description']?.toString(),
      episodes: json['episodes'] as int?,
      status: json['status']?.toString(),
      averageScore: (json['averageScore'] as num?)?.toDouble(),
      genres: (json['genres'] as List?)?.map((e) => e.toString()).toList() ?? [],
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
