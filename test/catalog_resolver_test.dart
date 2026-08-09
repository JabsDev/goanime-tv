import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/core/cache/app_caches.dart';
import 'package:goanime_tv/core/profile/profile_store.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/anime_source_adapter.dart';
import 'package:goanime_tv/core/sources/goyabu_adapter.dart';

/// Contract tests for the reviewed architecture:
///  - the canonical grid ([AnimeRepository.getCatalogEpisodes]) is pure
///    catalog (1..N, no provider url/source);
///  - the grid is always contiguous 1..N: N from Anime.episodes, else provider,
///    else the highest digit seen in episodesV2; v2 only decorates titles.
///  - the two new adapter verbs resolve on demand against the provider.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJBIiwidXNlciI6MX0.c';

  http.Response okJson(String json) => http.Response.bytes(
        utf8.encode(json),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppCaches.clearAll();
  });

  test('getCatalogEpisodes builds canonical 1..N with no provider data', () async {
    final repo = AnimeRepository();
    final eps = await repo.getCatalogEpisodes(
      Anime(name: 'One Piece', url: '', episodes: 5, anilistId: 123),
    );
    expect(eps.length, 5);
    expect(eps.map((e) => e.number).toList(), [1, 2, 3, 4, 5]);
    // CatalogEpisode exposes only number/title/thumbnail/description — no
    // provider url/source/owner leaks into the grid.
    expect(eps.first.title, isNull);
    for (final e in eps) {
      // Invalid field access would fail compilation; the type guarantees purity.
      expect(e.thumbnail, isNull);
    }
  });

  group('grade contígua 1..N com decoração por número real', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('catalog_resolver_test');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      ProfileStore.instance.resetForTest();
      await ProfileStore.instance.init();
      final p = await ProfileStore.instance
          .createAnilistProfile(token, 123, 'Avila', null);
      await ProfileStore.instance.switchProfile(p.id);
      AniListService.anilistRequestGap = const Duration(milliseconds: 2);
      AniListService.lastErrorStatus = AniListStatus.ok;
    });

    tearDown(() async {
      AniListService.httpOverride = null;
      AniListService.anilistRequestGap = const Duration(milliseconds: 800);
      await tmp.delete(recursive: true);
    });

    test('One Piece: grade 1..1172, títulos só na faixa 62..130', () async {
      AniListService.httpOverride = MockClient((req) async =>
          okJson(File('test/fixtures/op_result.json').readAsStringSync()));
      final repo = AnimeRepository(adapters: [_fakeCount(1172)]);

      final eps = await repo.getCatalogEpisodes(Anime(
        name: 'One Piece',
        url: 'https://animefire.io/animes/one-piece-todos-os-episodios',
        anilistId: 21,
        episodes: null,
        source: AnimeSource.animeFire,
      ));

      expect(eps.length, 1172, reason: 'contagem canônica do provider');
      expect(eps.first.number, 1);
      expect(eps.last.number, 1172);
      expect(eps.map((e) => e.number).toList(),
          [for (var i = 1; i <= 1172; i++) i]);
      // Sem título fora da faixa coberta pelo payload (EP 1 não tem título).
      expect(eps[0].title, isNull);
      expect(eps[61].title, contains('Episode 62')); // number 62
      expect(eps[129].title, contains('Episode 130')); // number 130
      expect(eps[130].title, isNull); // number 131 fora do payload
    });

    test('Black Clover: grade 1..170 com payload completo/crescente', () async {
      AniListService.httpOverride = MockClient((req) async =>
          okJson(File('test/fixtures/bc_result.json').readAsStringSync()));
      final repo = AnimeRepository(adapters: [_fakeCount(170)]);

      final eps = await repo.getCatalogEpisodes(Anime(
        name: 'Black Clover',
        url: 'https://animefire.io/animes/black-clover-todos-os-episodios',
        anilistId: 97940,
        episodes: 170,
        source: AnimeSource.animeFire,
      ));

      expect(eps.length, 170);
      expect(eps.first.title, contains('Episode 1'));
      expect(eps.last.title, contains('Episode 170'));
      expect(eps.map((e) => e.number).toList(),
          [for (var i = 1; i <= 170; i++) i]);
    });

    test('episodes:null + provider quebrada → grade 1..max(v2)', () async {
      AniListService.httpOverride = MockClient((req) async =>
          okJson(File('test/fixtures/op_result.json').readAsStringSync()));
      // Nenhum adapter implementado/contando → count 0 → fallback para 62..130.
      final repo = AnimeRepository(adapters: const <AnimeSourceAdapter>[]);

      final eps = await repo.getCatalogEpisodes(Anime(
        name: 'One Piece',
        url: '',
        anilistId: 21,
        episodes: null,
      ));

      expect(eps.length, 130, reason: 'última numeração real presente em v2');
      expect(eps.map((e) => e.number).toList(), [for (var i = 1; i <= 130; i++) i]);
      expect(eps[61].title, contains('Episode 62'));
    });

    test('v2 com gaps/duplicatas → grade contígua 1..N sem duplicar', () async {
      AniListService.httpOverride = MockClient((req) async =>
          okJson(File('test/fixtures/parcial_com_gaps.json').readAsStringSync()));
      final repo = AnimeRepository(adapters: [_fakeCount(7)]);

      final eps = await repo.getCatalogEpisodes(Anime(
        name: 'Com gaps',
        url: 'https://animefire.io/animes/x-todos-os-episodios',
        anilistId: 999,
        episodes: 7,
        source: AnimeSource.animeFire,
      ));

      expect(eps.length, 7);
      expect(eps[2].title, contains('Episode 3'));
      expect(eps[4].title, contains('Segunda parte'), reason: 'primeira vitória da duplicada');
      expect(eps[0].title, isNull);
    });

    test('cache login × deslogado são entradas distintas', () async {
      AniListService.httpOverride = MockClient((req) async =>
          okJson(File('test/fixtures/bc_result.json').readAsStringSync()));
      final repo = AnimeRepository(adapters: [_fakeCount(170)]);
      final anime = Anime(
        name: 'Black Clover',
        url: 'https://animefire.io/animes/black-clover-todos-os-episodios',
        anilistId: 97940,
        episodes: 170,
        source: AnimeSource.animeFire,
      );

      // deslogado → cache v1, sem títulos
      final local = ProfileStore.instance.createLocalProfile('local');
      await ProfileStore.instance.switchProfile(local.id);
      final anon = await repo.getCatalogEpisodes(anime);
      expect(anon.every((e) => e.title == null), isTrue,
          reason: 'deslogado não tem títulos');

      // logado → cache v2, com títulos (mesma anime, chaves distintas)
      final p = await ProfileStore.instance
          .createAnilistProfile(token, 123, 'Avila', null);
      await ProfileStore.instance.switchProfile(p.id);
      final logged = await repo.getCatalogEpisodes(anime);
      expect(logged.first.title, contains('Episode 1'));

      // A grid do cache v2 não "vaza" para a conta deslogada e vice-versa.
      await ProfileStore.instance.switchProfile(local.id);
      final anonAgain = await repo.getCatalogEpisodes(anime);
      expect(anonAgain.every((e) => e.title == null), isTrue);
    });
  });

  test('resolveAnime + resolveVideo resolve episode N on the provider', () async {
    final adapter = GoyabuAdapter(
      client: MockClient((req) async {
        final host = req.url.host;
        if (host == 'goyabu.io' && req.url.path == '/') {
          return http.Response(
            '<article class="boxAN"><a href="/anime/naruto">'
            '<img class="cover" src="/cap.jpg" alt="Naruto"></a></article>',
            200,
          );
        }
        if (host == 'goyabu.io' && req.url.path == '/anime/naruto') {
          return http.Response(
            'var allEpisodes = [{"id":1,"episodio":"1","link":"/1"},'
            '{"id":2,"episodio":"2","link":"/2"},'
            '{"id":3,"episodio":"3","link":"/3"}];',
            200,
          );
        }
        if (host == 'goyabu.io' && req.url.path == '/3') {
          return http.Response(
            'var layersData = [{"url":"https://cdn.example.com/v3.m3u8"}];',
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final match = await adapter.resolveAnime(
      Anime(name: 'Naruto', url: '', source: AnimeSource.goyabu),
    );
    expect(match, isNotNull);
    expect(match!.url, '/anime/naruto');

    final sources = await adapter.resolveVideo(match, 3);
    expect(sources, isNotEmpty);
    expect(sources.first.url, 'https://cdn.example.com/v3.m3u8');

    expect(await adapter.resolveVideo(match, 99), isEmpty);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docs;
  _FakePathProvider(this.docs);

  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
}

/// Fake adapter that reports a fixed episode count (the provider-count step of
/// the canonical grid) without network.
_FakeCountAdapter _fakeCount(int count) => _FakeCountAdapter(count);

class _FakeCountAdapter extends AnimeSourceAdapter {
  _FakeCountAdapter(this.count);
  final int count;

  @override
  AnimeSource get source => AnimeSource.animeFire;

  @override
  bool get implemented => true;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async =>
      ScraperResult.success(const <Anime>[]);

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async =>
      ScraperResult.success([
        for (var i = 1; i <= count; i++)
          Episode(number: '$i', url: 'https://animefire.io/v/$i'),
      ]);

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async =>
      ScraperResult.success(const <VideoSource>[]);

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async =>
      throw UnimplementedError();
}