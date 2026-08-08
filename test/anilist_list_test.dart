import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/core/profile/profile_store.dart';

/// Regressão b81de7e: `nextAiringEpisode` fora do schema MediaList zerou as
/// listas (HTTP 400) e o `logout()` em 400 deslogava a cada boot. Bateria
/// T1-T5 do plano v2 — shape da query, parse fim-a-fim, e 400/401/429.
class _FakePathProvider extends PathProviderPlatform {
  final String docs;
  _FakePathProvider(this.docs);

  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
}

/// Payload realista no formato que o AniList devolve: `nextAiringEpisode`
/// DENTRO de `media` (nunca no nível de `entries`).
Map<String, dynamic> realisticListsPayload() => {
      'data': {
        'MediaListCollection': {
          'lists': [
            {
              'name': 'Watching',
              'entries': [
                {
                  'progress': 5,
                  'status': 'CURRENT',
                  'updatedAt': 1720000000,
                  'media': {
                    'id': 21,
                    'title': {
                      'romaji': 'One Piece',
                      'english': 'One Piece',
                      'native': 'ワンピース',
                    },
                    'coverImage': {
                      'large': 'https://x.test/img_l.jpg',
                      'extraLarge': 'https://x.test/img_xl.jpg',
                    },
                    'bannerImage': 'https://x.test/banner.jpg',
                    'episodes': 1100,
                    'format': 'TV',
                    'status': 'RELEASING',
                    'nextAiringEpisode': {
                      'episode': 1101,
                      'timeUntilAiring': 432000,
                    },
                  },
                },
              ],
            },
            {
              'name': 'Planning',
              'entries': [
                {
                  'media': {
                    'id': 99,
                    'title': {'romaji': 'Bleach', 'english': null, 'native': null},
                    'coverImage': {'large': 'http://x.test/b.jpg', 'extraLarge': null},
                  },
                },
              ],
            },
          ],
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const token =
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJBIiwidXNlciI6MX0.abc';

  late Directory tmp;

  http.Response okJson(Map<String, dynamic> json) => http.Response.bytes(
        utf8.encode(jsonEncode(json)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('anilist_list_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
    // Perfil AniList ativo: fonte de verdade do token.
    final p = await ProfileStore.instance.createAnilistProfile(token, 123, 'Avila', null);
    await ProfileStore.instance.switchProfile(p.id);
    // Client override + pacing rápido p/ não atrasar os testes.
    AniListService.lastErrorStatus = AniListStatus.ok;
    AniListService.anilistRequestGap = const Duration(milliseconds: 2);
  });

  tearDown(() async {
    AniListService.httpOverride = null;
    AniListService.anilistRequestGap = const Duration(milliseconds: 800);
    await tmp.delete(recursive: true);
  });

  test('T1: listQuery mantém nextAiringEpisode dentro de media', () {
    final q = AniListService.listQuery;
    final mediaIdx = q.indexOf('media {');
    final nextIdx = q.indexOf('nextAiringEpisode');
    expect(mediaIdx, greaterThan(0), reason: 'query deve ter bloco media');
    expect(nextIdx, greaterThan(mediaIdx),
        reason: 'nextAiringEpisode deve vir DEPOIS de media {');
    // Nenhum outro bloco `entries {` entre media { e nextAiringEpisode —
    // se houvesse, o campo teria voltado para o nível errado.
    final between = q.substring(mediaIdx, nextIdx);
    expect(between.contains('entries {'), isFalse,
        reason: 'sem aninhamento de entries entre media e nextAiringEpisode');
  });

  test('T2: parse fim-a-fim da resposta real; query usada é a const', () async {
    String? sentQuery;
    AniListService.httpOverride = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      sentQuery = body['query'] as String?;
      return okJson(realisticListsPayload());
    });

    final groups = await AniListService.getUserAnimeList();

    // A query enviada ao servidor é a MESMA const que o teste T1 valida —
    // bind direto entre shape e tráfego real.
    expect(sentQuery, AniListService.listQuery);
    expect(groups, hasLength(2));
    expect(groups[0].name, 'Watching');
    expect(groups[1].name, 'Planning');

    final watching = groups
        .expand((g) => g.entries.where((e) => e.status == 'CURRENT'))
        .toList();
    expect(watching, hasLength(1));
    final e = watching.first;
    expect(e.media.id, 21);
    expect(e.media.title, 'One Piece');
    expect(e.progress, 5);
    expect(e.status, 'CURRENT');
    // nextAiringEpisode extraído de media.nextAiringEpisode na camada correta.
    expect(e.nextEpisode, 1101);
    expect(e.timeUntilAiring, 432000);

    expect(AniListService.lastErrorStatus, AniListStatus.ok);

    // Cache persistido (getUserAnimeList escreve quando não-vazio).
    final cached = await AniListService.getCachedAnimeLists();
    expect(cached, hasLength(2));
    expect(cached[0].entries.single.nextEpisode, 1101);
  });

  test('T3: 400 NÃO desloga e NÃO vira authError', () async {
    AniListService.httpOverride = MockClient(
        (req) async => http.Response('{"errors":[{"message":"bad"}]}', 400));

    final lists = await AniListService.getUserAnimeList();
    expect(lists, isEmpty);
    expect(AniListService.lastErrorStatus, isNot(AniListStatus.authError),
        reason: '400 é erro de query, não de sessão');
    expect(AniListService.lastErrorStatus, AniListStatus.serverError);
    // Token do perfil intacto — ninguém deslogou.
    expect(await AniListService.getToken(), token);
  });

  test('T4: 401 desloga (token sai do perfil)', () async {
    AniListService.httpOverride = MockClient(
        (req) async => http.Response('{"errors":{"message":"unauth"}}', 401));

    final lists = await AniListService.getUserAnimeList();
    expect(lists, isEmpty);
    expect(AniListService.lastErrorStatus, AniListStatus.authError);
    expect(await AniListService.getToken(), isNull,
        reason: '401 => logout limpa o token do perfil');
  });

  test('T5: 429 vira rateLimited e não mexe no token', () async {
    AniListService.httpOverride = MockClient(
        (req) async => http.Response('rate limit', 429));

    final lists = await AniListService.getUserAnimeList();
    expect(lists, isEmpty);
    expect(AniListService.lastErrorStatus, AniListStatus.rateLimited);
    expect(await AniListService.getToken(), token);
  });
}