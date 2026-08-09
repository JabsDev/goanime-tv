// Regression for Bug 1 grid core: `getEpisodesV2` must number episodes by the
// real number embedded in the title, never by array position. One Piece's real
// payload has 69 items ordered 130→62 (descending) — the result must carry real
// numbers, so the repository can build a contiguous 1..N grid over it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/core/cache/app_caches.dart';
import 'package:goanime_tv/core/profile/profile_store.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String docs;
  _FakePathProvider(this.docs);

  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJBIiwidXNlciI6MX0.c';

  http.Response okJson(String json) => http.Response.bytes(
        utf8.encode(json),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('anilist_episodes_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
    final p =
        await ProfileStore.instance.createAnilistProfile(token, 123, 'Avila', null);
    await ProfileStore.instance.switchProfile(p.id);
    AppCaches.clearAll();
    AniListService.lastErrorStatus = AniListStatus.ok;
    AniListService.anilistRequestGap = const Duration(milliseconds: 2);
  });

  tearDown(() async {
    AniListService.httpOverride = null;
    AniListService.anilistRequestGap = const Duration(milliseconds: 800);
    await tmp.delete(recursive: true);
  });

  test('getEpisodesV2 numera pelo número real do título (One Piece 62..130)',
      () async {
    final raw = File('test/fixtures/op_result.json').readAsStringSync();
    AniListService.httpOverride = MockClient((req) async => okJson(raw));

    final eps = await AniListService.getEpisodesV2(21);
    expect(eps.length, 69);
    // Real numbers, not positional 1..69.
    expect(eps.first.number, '130');
    expect(eps.last.number, '62');
    expect(eps.map((e) => int.parse(e.number)).toSet(), isNot(contains(1)));
    expect(eps.first.title, contains('Episode 130'));
    expect(eps.last.thumbnail, isNotEmpty);
  });

  test('getEpisodesV2 sem token retorna lista vazia', () async {
    // Troca para um perfil local (sem token AniList).
    final local = ProfileStore.instance.createLocalProfile('local');
    await ProfileStore.instance.switchProfile(local.id);

    AniListService.httpOverride = MockClient((req) async =>
        okJson(File('test/fixtures/op_result.json').readAsStringSync()));
    expect(await AniListService.getEpisodesV2(21), isEmpty);
  });

  test('getEpisodesV2 descarta itens sem número no título', () async {
    final json = {
      'data': {
        'Media': {
          'id': 1,
          'streamingEpisodes': [
            {'title': 'Episode 5 - Real', 'thumbnail': 't5'},
            {'title': 'Special: Recap', 'thumbnail': 'tS'},
            {'title': 'Movie 2', 'thumbnail': 'tM'},
            {'title': 'no numero aqui', 'thumbnail': 'tX'},
          ],
        },
      },
    };
    AniListService.httpOverride =
        MockClient((req) async => okJson(jsonEncode(json)));

    final eps = await AniListService.getEpisodesV2(1);
    expect(eps.length, 1);
    expect(eps.single.number, '5');
    expect(eps.single.title, 'Episode 5 - Real');
  });
}