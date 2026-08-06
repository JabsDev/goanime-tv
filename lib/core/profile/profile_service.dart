import 'package:flutter/foundation.dart';

import '../../data/models/anilist_models.dart';
import '../../data/models/profile.dart';
import 'profile_store.dart';

class ProfileService {
  static final ProfileService instance = ProfileService._();
  ProfileService._();

  final ValueNotifier<Profile?> _activeVN = ValueNotifier<Profile?>(null);
  final ValueNotifier<List<Profile>> _profilesVN =
      ValueNotifier<List<Profile>>([]);

  ValueListenable<Profile?> get activeListenable => _activeVN;
  ValueListenable<List<Profile>> get profilesListenable => _profilesVN;

  Profile? get currentProfile => ProfileStore.instance.currentProfile;
  List<Profile> get profiles => ProfileStore.instance.profiles;
  bool get hasProfiles => profiles.isNotEmpty;

  Map<String, dynamic>? get currentProfileListsCache =>
      ProfileStore.instance.getListsCache();

  Future<void> setCurrentProfileListsCache(Map<String, dynamic>? data) =>
      ProfileStore.instance.setListsCache(data);

  Future<void> init() async {
    await ProfileStore.instance.init();
    _activeVN.value = ProfileStore.instance.currentProfile;
    _profilesVN.value = ProfileStore.instance.profiles;
  }

  Profile createLocalProfile(String name) {
    final p = ProfileStore.instance.createLocalProfile(name);
    _profilesVN.value = List.of(ProfileStore.instance.profiles);
    return p;
  }

  Future<Profile> createAnilistProfile(
      String token, AniListUser user) async {
    final p = await ProfileStore.instance.createAnilistProfile(
      token,
      user.id,
      user.name,
      user.avatar,
    );
    _profilesVN.value = List.of(ProfileStore.instance.profiles);
    return p;
  }

  Future<void> switchProfile(String id) async {
    await ProfileStore.instance.switchProfile(id);
    _activeVN.value = ProfileStore.instance.currentProfile;
  }

  Future<void> deleteProfile(String id) async {
    await ProfileStore.instance.deleteProfile(id);
    _activeVN.value = ProfileStore.instance.currentProfile;
    _profilesVN.value = List.of(ProfileStore.instance.profiles);
  }

  void updateCurrentProfileAnilist({
    String? token,
    int? userId,
    String? userName,
    String? avatar,
    bool clear = false,
  }) {
    ProfileStore.instance.updateCurrentAnilist(
      token: token,
      userId: userId,
      userName: userName,
      avatar: avatar,
      clear: clear,
    );
    _activeVN.value = ProfileStore.instance.currentProfile;
  }
}
