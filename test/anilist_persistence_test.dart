import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/anilist/anilist_auth_service.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/core/profile/profile_store.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String docs;
  _FakePathProvider(this.docs);

  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const tokenA =
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJBIiwidXNlciI6MX0.abc';
  const tokenB =
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJCIiwidXNlciI6Mn0.def';

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('profile_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('cache de sessão: saveToken persiste e removeToken limpa', () async {
    await AnilistAuthService.saveToken(tokenA);
    expect(await AnilistAuthService.getToken(), tokenA);

    await AnilistAuthService.removeToken();
    expect(await AnilistAuthService.getToken(), isNull);
  });

  test('perfil é a fonte de verdade do token; troca de perfil não vaza', () async {
    final pA = ProfileStore.instance.createLocalProfile('A');
    await ProfileStore.instance.switchProfile(pA.id);
    await ProfileStore.instance.updateCurrentAnilist(token: tokenA, userId: 1);

    final pB = ProfileStore.instance.createLocalProfile('B');
    await ProfileStore.instance.switchProfile(pB.id);
    expect(ProfileStore.instance.currentProfile?.anilistToken, isNull);

    await ProfileStore.instance.switchProfile(pA.id);
    expect(ProfileStore.instance.currentProfile?.anilistToken, tokenA);
  });

  test('getToken lê só o perfil ativo; cache global não decide auth', () async {
    await AnilistAuthService.saveToken(tokenA);
    final p = ProfileStore.instance.createLocalProfile('local');
    await ProfileStore.instance.switchProfile(p.id);

    // Perfil local sem token: mesmo com cache global, não está logado.
    expect(await AniListService.getToken(), isNull);

    await ProfileStore.instance.updateCurrentAnilist(token: tokenB, userId: 2);
    expect(await AniListService.getToken(), tokenB);
  });

  test('isLoggedIn reflete o token do perfil (não o cache global)', () async {
    await AnilistAuthService.saveToken(tokenA);
    final p = ProfileStore.instance.createLocalProfile('local');
    await ProfileStore.instance.switchProfile(p.id);

    expect(await AniListService.isLoggedIn(), isFalse);

    await ProfileStore.instance.updateCurrentAnilist(token: tokenB, userId: 2);
    expect(await AniListService.isLoggedIn(), isTrue);
  });
}