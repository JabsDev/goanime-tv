enum ProfileType { local, anilist }

/// Nome temporário do perfil criado durante o login AniList
/// (profile_switcher_screen)._startAnilistLogin renomeia para o username real
/// em updateCurrentAnilist; se o app fechar no meio, refreshUser cura na
/// próxima abertura.
const kAnilistPlaceholderProfileName = '__anilist_pending__';

/// Versão do esquema de dados persistidos. Qualquer mudança de formato
/// incrementa este valor e adiciona uma migração no mesmo PR (I-4).
const int kSchemaVersion = 1;

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
        'schema': kSchemaVersion,
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
    ProfileType? type,
    String? anilistToken,
    int? anilistUserId,
    String? anilistUserName,
    String? anilistAvatar,
    bool clearAnilist = false,
  }) {
    return Profile(
      id: id,
      displayName: displayName ?? this.displayName,
      type: type ?? this.type,
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
