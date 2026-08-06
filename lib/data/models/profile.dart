enum ProfileType { local, anilist }

class Profile {
  final String id;
  final String displayName;
  final ProfileType type;
  final DateTime createdAt;

  String? anilistToken;
  int? anilistUserId;
  String? anilistUserName;
  String? anilistAvatar;

  Profile({
    required this.id,
    required this.displayName,
    required this.type,
    required this.createdAt,
    this.anilistToken,
    this.anilistUserId,
    this.anilistUserName,
    this.anilistAvatar,
  });

  bool get isAnilist => type == ProfileType.anilist;
  bool get hasAnilistToken => anilistToken != null && anilistToken!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'type': type == ProfileType.anilist ? 'anilist' : 'local',
        'createdAt': createdAt.toIso8601String(),
        if (anilistToken != null) 'anilistToken': anilistToken,
        if (anilistUserId != null) 'anilistUserId': anilistUserId,
        if (anilistUserName != null) 'anilistUserName': anilistUserName,
        if (anilistAvatar != null) 'anilistAvatar': anilistAvatar,
      };

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      type: (json['type'] as String) == 'anilist'
          ? ProfileType.anilist
          : ProfileType.local,
      createdAt: DateTime.parse(json['createdAt'] as String),
      anilistToken: json['anilistToken'] as String?,
      anilistUserId: json['anilistUserId'] as int?,
      anilistUserName: json['anilistUserName'] as String?,
      anilistAvatar: json['anilistAvatar'] as String?,
    );
  }

  Profile copyWith({
    String? displayName,
    String? anilistToken,
    int? anilistUserId,
    String? anilistUserName,
    String? anilistAvatar,
    bool clearAnilist = false,
  }) {
    return Profile(
      id: id,
      displayName: displayName ?? this.displayName,
      type: type,
      createdAt: createdAt,
      anilistToken: clearAnilist ? null : (anilistToken ?? this.anilistToken),
      anilistUserId:
          clearAnilist ? null : (anilistUserId ?? this.anilistUserId),
      anilistUserName:
          clearAnilist ? null : (anilistUserName ?? this.anilistUserName),
      anilistAvatar:
          clearAnilist ? null : (anilistAvatar ?? this.anilistAvatar),
    );
  }
}
