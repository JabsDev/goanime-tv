// Bug 2 regression: `resolveProvidersForEpisode` must distinguish WHY a
// provider didn't deliver — page not found (`notFound`) vs page matched but
// the extractor couldn't get a video (`matchedUnavailable`, e.g. Blogger SPA) —
// and must NOT drop a persisted match in the matchedUnavailable case.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/cache/app_caches.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/anime_fire_adapter.dart';
import 'package:goanime_tv/core/sources/anime_source_adapter.dart';
import 'package:goanime_tv/core/storage/provider_match_store.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';

/// New AnimeFire JSON API fixtures (site rebuild 2026 — no more HTML).
const _searchJson =
    '{"data":[{"id":"bc789","title":"Black Clover","audio":"Dublado",'
    '"poster_src":"https://image.tmdb.org/t/p/original/bc.jpg"}]}';

String _animeJson(List<Map<String, Object>> episodes) =>
    '{"data":{"episodes":['
    '${episodes.map((e) => '{"id":"${e['id']}","title":"${e['title']}",'
    '"audio":"Dublado","season":1,"number":${e['number']},'
    '"still_src":"https://image.tmdb.org/t/p/original/bc${e['number']}.jpg",'
    '"synopsis":"sinopse"}').join(',')}'
    ']}}';

String _episodeJson(List<String> streamUrls) =>
    '{"data":{"id":"ep1","title":"Ep 1","audio":"Dublado","season":1,'
    '"number":1,"streams":['
    '${streamUrls.map((u) => '{"audio":"dublado","is_mtl":false,'
    '"is_offline":false,"url":"$u","qualities":["480p"],'
    '"chapters":[],"thumbnails":null}').join(',')}'
    ']}}';

AnimeFireAdapter _adapter(String episodeJson, {void Function()? onSearch}) {
  return AnimeFireAdapter(
    client: MockClient((req) async {
      final path = req.url.path;
      if (path == '/animes/pesquisar') {
        onSearch?.call();
        return http.Response(_searchJson, 200);
      }
      if (path == '/anime/bc789') {
        return http.Response(
            _animeJson([
              {'id': 'ep1', 'number': 1, 'title': 'Ep 1'}
            ]),
            200);
      }
      if (path == '/episode/ep1') {
        return http.Response(episodeJson, 200);
      }
      return http.Response('not found', 404);
    }),
  );
}

Anime _anime({required int id}) => Anime(
      name: 'Black Clover',
      url: '',
      source: AnimeSource.animeFire,
      anilistId: id,
    );

/// Instant adapter: search/match/video resolve without any delay.
class _FastAdapter extends AnimeSourceAdapter {
  @override
  AnimeSource get source => AnimeSource.animeFire;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    return ScraperResult.success([
      Anime(name: query, url: 'http://animefire.io/animes/$query', source: source),
    ]);
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    return ScraperResult.success([
      Episode(number: '1', url: '${anime.url}/1', owner: anime),
    ]);
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    return ScraperResult.success([
      VideoSource(url: 'https://cdn.example.com/720.mp4', quality: '720p'),
    ]);
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    return AvailabilityReport(source: source, animeName: animeName);
  }
}

/// Adapter que explode no match: prova que throw/timeout cai em `errored`
/// (visível, com retry) em vez de sumir em silêncio de todos os conjuntos.
class _ThrowingAdapter extends AnimeSourceAdapter {
  @override
  AnimeSource get source => AnimeSource.goyabu;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    throw StateError('boom');
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) {
    throw UnimplementedError();
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    return AvailabilityReport(source: source, animeName: animeName);
  }
}

/// Slow adapter: page match and video extraction take [delay] each, proving the
/// partial gate returns before a source like this finishes.
class _SlowAdapter extends AnimeSourceAdapter {
  _SlowAdapter(this.delay);

  final Duration delay;

  @override
  AnimeSource get source => AnimeSource.goyabu;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    return ScraperResult.success([
      Anime(name: query, url: 'http://goyabu.io/animes/$query', source: source),
    ]);
  }

  @override
  Future<Anime?> resolveAnime(Anime animeRef) async {
    await Future.delayed(delay);
    return Anime(
      name: animeRef.name,
      url: 'http://goyabu.io/animes/$animeRef',
      source: source,
    );
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    return ScraperResult.success([
      Episode(number: '1', url: '${anime.url}/1', owner: anime),
    ]);
  }

  @override
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber,
      {Anime? catalog}) async {
    await Future.delayed(delay);
    return super.resolveVideo(match, episodeNumber, catalog: catalog);
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    return ScraperResult.success([
      VideoSource(url: 'https://cdn.goyabu.com/1080.mp4', quality: '1080p'),
    ]);
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    return AvailabilityReport(source: source, animeName: animeName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppCaches.clearAll();
  });

  test('página achada + episódio sem streams → matchedUnavailable', () async {
    final repo =
        AnimeRepository(adapters: [_adapter(_episodeJson(const []))]);
    final res = await repo.resolveProvidersForEpisode(_anime(id: 21), 1);

    expect(res.providers, isEmpty);
    expect(res.notFound, isEmpty);
    expect(res.matchedUnavailable, contains(AnimeSource.animeFire));
  });

  test('throw no resolve → errored (não some em silêncio)', () async {
    final repo = AnimeRepository(adapters: [_ThrowingAdapter()]);
    final res = await repo.resolveProvidersForEpisode(_anime(id: 24), 1);

    expect(res.providers, isEmpty);
    expect(res.matchedUnavailable, isEmpty);
    expect(res.notFound, isEmpty);
    expect(res.errored, contains(AnimeSource.goyabu));
    expect(res.complete, isTrue);
  });

  test('página não achada → notFound', () async {
    // Search sem resultado: resolveAnime retorna null.
    final adapter = AnimeFireAdapter(
      client: MockClient((req) async => http.Response('', 200)),
    );
    final repo = AnimeRepository(adapters: [adapter]);
    final res = await repo.resolveProvidersForEpisode(_anime(id: 22), 1);

    expect(res.providers, isEmpty);
    expect(res.matchedUnavailable, isEmpty);
    expect(res.notFound, contains(AnimeSource.animeFire));
  });

  test('match persistido NÃO é removido no caso matchedUnavailable', () async {
    const identity = '23';
    const url = 'https://animefire.io/anime/bc789';
    await ProviderMatchStore.saveMatch(
        identity, AnimeSource.animeFire, url);

    var searches = 0;
    final repo = AnimeRepository(
        adapters: [_adapter(_episodeJson(const []), onSearch: () => searches++)]);
    final anime = _anime(id: 23);
    // identity com anilistId 23 bate com o match pré-salvo.
    expect(ProviderMatchStore.identity(anime), identity);

    final res = await repo.resolveProvidersForEpisode(anime, 1);

    expect(res.matchedUnavailable, contains(AnimeSource.animeFire));
    expect(searches, 0, reason: 'não deve re-serializar uma página já casada');
    // O match persistido permanece para o próximo toque.
    expect(await ProviderMatchStore.urlFor(identity, AnimeSource.animeFire),
        url, reason: 'removeMatch não deve rodar nesta branch');
  });

  test('match persistido morto (página sem episódios) → remove + redescobre',
      () async {
    const identity = '30';
    // URL legada do site antigo: sem id válido na API.
    const stale = 'https://animefire.io/animes/black-clover-todos-os-episodios';
    await ProviderMatchStore.saveMatch(
        identity, AnimeSource.animeFire, stale);

    var searches = 0;
    final repo = AnimeRepository(adapters: [
      _adapter(_episodeJson(['https://akumast.net/i/x/m.jpg']),
          onSearch: () => searches++)
    ]);
    final res =
        await repo.resolveProvidersForEpisode(_anime(id: 30), 1);

    // Re-redescobriu via busca e resolveu o vídeo na página nova.
    expect(searches, 1);
    expect(res.providers[AnimeSource.animeFire], isNotEmpty);
    expect(await ProviderMatchStore.urlFor(identity, AnimeSource.animeFire),
        'https://animefire.io/anime/bc789');
  });

  test('página achada + vídeo ok → providers e match persistido', () async {
    final repo = AnimeRepository(adapters: [
      _adapter(_episodeJson(['https://akumast.net/i/x/m.jpg']))
    ]);
    final anime = _anime(id: 24);
    final res = await repo.resolveProvidersForEpisode(anime, 1);

    expect(res.matchedUnavailable, isEmpty);
    expect(res.providers[AnimeSource.animeFire], isNotEmpty);
    expect(res.providers[AnimeSource.animeFire]!.first.url,
        'https://akumast.net/i/x/m.jpg');
    expect(
        await ProviderMatchStore.urlFor(
            ProviderMatchStore.identity(anime), AnimeSource.animeFire),
        isNotNull);
  });

  test('getVideoSources: episódio sem streams → EmptyResultError', () async {
    final adapter = _adapter(_episodeJson(const []));
    final vs = await adapter.getVideoSources(
      Episode(
        number: '1',
        url: 'https://api.animefire.io/episode/ep1',
        owner: _anime(id: 1),
      ),
    );
    expect(vs, isA<Failure<List<VideoSource>>>());
    final err = ((vs as Failure).error);
    expect(err, isA<EmptyResultError>());
  });

  test(
      'partial: retorna quando a melhor fonte resolve sem esperar a mais lenta, '
      'e a lenta chega via onUpdate', () async {
    final repo = AnimeRepository(adapters: [
      _FastAdapter(),
      _SlowAdapter(const Duration(milliseconds: 400)),
    ]);
    final anime = _anime(id: 25);

    final updates = <EpisodeResolution>[];
    final sw = Stopwatch()..start();
    final res = await repo.resolveProvidersForEpisode(
      anime,
      1,
      partial: true,
      onUpdate: updates.add,
    );
    sw.stop();

    // Retorna com a AnimeFire (rápida) sem esperar os 400ms da Goyabu.
    expect(res.providers[AnimeSource.animeFire], isNotEmpty);
    expect(res.matchedUnavailable, isEmpty);
    expect(res.complete, isFalse);
    expect(sw.elapsedMilliseconds, lessThan(300),
        reason: 'não deve esperar a fonte lenta terminar');

    // A fonte lenta termina em background e o último onUpdate é completo.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!updates.any((u) => u.complete) && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(updates.any((u) => u.complete), isTrue,
        reason: 'fonte lenta deve resolver em background');
    final last = updates.last;
    expect(last.complete, isTrue);
    expect(last.providers[AnimeSource.goyabu], isNotEmpty);
    expect(last.providers[AnimeSource.animeFire], isNotEmpty,
        reason: 'snapshot acumulativo mantém fontes já resolvidas');
  });

  test('partial: fonte lenta além do deadline → retorno vazio não-completo '
      'e background completa depois', () async {
    // 2 x 2s > deadline parcial de 3.5s — a única fonte não resolve a tempo.
    final repo = AnimeRepository(adapters: [
      _SlowAdapter(const Duration(seconds: 2)),
    ]);
    final anime = _anime(id: 26);

    final updates = <EpisodeResolution>[];
    final sw = Stopwatch()..start();
    final res = await repo.resolveProvidersForEpisode(
      anime,
      1,
      partial: true,
      onUpdate: updates.add,
    );
    sw.stop();

    // O método NÃO espera os 4s da fonte: o deadline parcial devolve o que há
    // (nada) marcado como incompleto.
    expect(sw.elapsed, lessThan(const Duration(seconds: 4)),
        reason: 'não pode ficar preso na fonte lenta');
    expect(res.providers, isEmpty);
    expect(res.complete, isFalse);

    // A fonte lenta termina em background (~4s) e chega via onUpdate.
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (!updates.any((u) => u.complete) && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 25));
    }
    expect(updates.any((u) => u.complete), isTrue,
        reason: 'fonte lenta deve fechar o fluxo em background');
    expect(updates.last.providers[AnimeSource.goyabu], isNotEmpty);
  });

  test('non-partial preserva semântica antiga: espera TODAS as fontes', () async {
    final repo = AnimeRepository(adapters: [
      _FastAdapter(),
      _SlowAdapter(const Duration(milliseconds: 60)),
    ]);
    final anime = _anime(id: 27);

    final sw = Stopwatch()..start();
    final res = await repo.resolveProvidersForEpisode(anime, 1);
    sw.stop();

    expect(res.providers.keys.toSet(),
        {AnimeSource.animeFire, AnimeSource.goyabu});
    expect(res.complete, isTrue);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(60),
        reason: 'modo full espera a fonte lenta terminar');
  });

  test('BUGFIX fontes não carregam na 2ª abertura: cache hit ainda chama onUpdate',
      () async {
    final repo = AnimeRepository(adapters: [_FastAdapter()]);
    final anime = _anime(id: 29);

    // 1ª resolução: popula o cache (happy-path).
    await repo.resolveProvidersForEpisode(
      anime,
      1,
      partial: true,
      onUpdate: (_) {},
    );
    final identity = ProviderMatchStore.identity(anime);
    expect(
      AppCaches.resolutions
          .get<Map<AnimeSource, List<VideoSource>>>('$identity:1'),
      isNotNull,
      reason: 'a 1ª resolução tem que ter sido cacheada para o teste 2 bater o bug',
    );

    // 2ª abertura dentro do TTL → cache hit NÃO pode deixar o consumidor preso
    // em loading: o onUpdate precisa ser alimentado mesmo sem fan-out.
    final secondUpdates = <EpisodeResolution>[];
    final res = await repo.resolveProvidersForEpisode(
      anime,
      1,
      partial: true,
      onUpdate: secondUpdates.add,
    );

    expect(secondUpdates, isNotEmpty,
        reason: 'cache hit deve alimentar o onUpdate/consumidor');
    expect(secondUpdates.last.providers, isNotEmpty);
    expect(secondUpdates.last.complete, isTrue);
    expect(res.providers[AnimeSource.animeFire], isNotEmpty);
  });

  group('AnimeFire DASH multi-quality + temporadas (botão único + não carrega)',
      () {
    AnimeFireAdapter seasonAdapter(
      Map<String, String> episodeJsonById,
      String animeJson,
    ) {
      return AnimeFireAdapter(
        client: MockClient((req) async {
          final path = req.url.path;
          if (path == '/animes/pesquisar') {
            return http.Response(_searchJson, 200);
          }
          if (path == '/anime/bc789') {
            return http.Response(animeJson, 200);
          }
          final id = req.url.pathSegments.isEmpty
              ? ''
              : req.url.pathSegments.last;
          final body = episodeJsonById[id];
          if (body != null) return http.Response(body, 200);
          return http.Response('not found', 404);
        }),
      );
    }

    // 2 temporadas: S1E1..S1E2 (abs 1..2), S2E1..S2E2 (abs 3..4).
    const seasonAnimeJson = '{"data":{"seasons":['
        '{"number":1,"first_episode_number":1},'
        '{"number":2,"first_episode_number":3}],'
        '"episodes":['
        '{"id":"s1e1","title":"E1","audio":"Dublado","season":1,"number":1},'
        '{"id":"s1e2","title":"E2","audio":"Dublado","season":1,"number":2},'
        '{"id":"s2e1","title":"E3","audio":"Dublado","season":2,"number":1},'
        '{"id":"s2e2","title":"E4","audio":"Dublado","season":2,"number":2}'
        ']}}';

    String dashEpisodeJson({
      required List<String> qualitiesDub,
      required List<String> qualitiesLeg,
      bool legOffline = false,
    }) {
      String stream(String audio, List<String> qs, String url) =>
          '{"audio":"$audio","is_mtl":false,"is_offline":false,'
          '"url":"$url","qualities":[${qs.map((q) => '"$q"').join(',')}],'
          '"chapters":[],"thumbnails":null}';
      final leg = legOffline
          ? '{"audio":"legendado","is_mtl":false,"is_offline":true,'
              '"url":null,"qualities":["480p"],"chapters":[],"thumbnails":null}'
          : stream('legendado', qualitiesLeg, 'https://akumast.net/i/leg/m.jpg');
      return '{"data":{"id":"s2e1","title":"E3","audio":"Dublado",'
          '"season":2,"number":1,"streams":['
          '${stream('dublado', qualitiesDub, 'https://akumast.net/i/dub/m.jpg')},'
          '$leg]}}';
    }

    test('getEpisodes mapeia (season,number) → absoluto via offsets', () async {
      final adapter = seasonAdapter(const {}, seasonAnimeJson);
      final eps = await adapter.getEpisodes(
        Anime(
            name: 'Black Clover',
            url: 'https://animefire.io/anime/bc789',
            source: AnimeSource.animeFire),
      );
      expect(eps, isA<Success<List<Episode>>>());
      final numbers =
          (eps as Success<List<Episode>>).data.map((e) => e.number).toList();
      expect(numbers, ['1', '2', '3', '4']);
    });

    test('resolveVideo(3) alcança S2E1 (antes: número repetido/errava)', () async {
      final adapter = seasonAdapter(
        {'s2e1': dashEpisodeJson(qualitiesDub: const ['480p'], qualitiesLeg: const ['480p'])},
        seasonAnimeJson,
      );
      final sources = await adapter.resolveVideo(
        Anime(
            name: 'Black Clover',
            url: 'https://animefire.io/anime/bc789',
            source: AnimeSource.animeFire),
        3,
      );
      expect(sources.map((s) => s.url),
          contains('https://akumast.net/i/dub/m.jpg'));
    });

    test('seasonFromCatalogName extrai a temporada do título', () {
      expect(
          AnimeFireAdapter.seasonFromCatalogName(
              'Tensei Shitara Slime Datta Ken 4th Season'),
          4);
      expect(
          AnimeFireAdapter.seasonFromCatalogName(
              'That Time I Got Reincarnated as a Slime Season 2'),
          2);
      expect(AnimeFireAdapter.seasonFromCatalogName('Black Clover 2nd Season'),
          2);
      expect(AnimeFireAdapter.seasonFromCatalogName('Black Clover'), isNull);
      expect(
          AnimeFireAdapter.seasonFromCatalogName(
              'That Time I Got Reincarnated as a Slime'),
          isNull);
    });

    test('catálogo "2nd Season" EP1 → S2E1 (não S1E1)', () async {
      const s1e1Json = '{"data":{"id":"s1e1","title":"E1","audio":"Dublado",'
          '"season":1,"number":1,"streams":[{"audio":"legendado",'
          '"is_mtl":false,"is_offline":false,'
          '"url":"https://akumast.net/i/s1e1/m.jpg","qualities":["360p"],'
          '"chapters":[],"thumbnails":null}]}}';
      final adapter = seasonAdapter(
        {
          's1e1': s1e1Json,
          's2e1': dashEpisodeJson(
              qualitiesDub: const ['480p'], qualitiesLeg: const ['480p']),
        },
        seasonAnimeJson,
      );
      final match = Anime(
          name: 'Black Clover',
          url: 'https://animefire.io/anime/bc789',
          source: AnimeSource.animeFire);
      // Sem hint de temporada: absoluto 1 == S1E1.
      final abs = await adapter.resolveVideo(match, 1);
      expect(abs.map((s) => s.url),
          contains('https://akumast.net/i/s1e1/m.jpg'));
      // Com hint: relativo 1 da S2 == S2E1.
      final rel = await adapter.resolveVideo(
        match,
        1,
        catalog: Anime(
            name: 'Black Clover 2nd Season',
            url: '',
            source: AnimeSource.anilist),
      );
      expect(rel.map((s) => s.url),
          contains('https://akumast.net/i/dub/m.jpg'));
      expect(rel.map((s) => s.url),
          isNot(contains('https://akumast.net/i/s1e1/m.jpg')));
    });

    test('getVideoSources multi-quality → Auto + 1 fonte por qualidade',
        () async {
      final adapter = seasonAdapter(
        {
          's2e1': dashEpisodeJson(
            qualitiesDub: const ['480p', '720p', '1080p'],
            qualitiesLeg: const ['480p', '720p'],
          )
        },
        seasonAnimeJson,
      );
      final vs = await adapter.getVideoSources(
        Episode(number: '3', url: 'https://api.animefire.io/episode/s2e1'),
      );
      expect(vs, isA<Success<List<VideoSource>>>());
      final data = (vs as Success<List<VideoSource>>).data;
      // dublado: Auto+480+720+1080; legendado: Auto+480+720.
      expect(data, hasLength(7));
      for (final s in data) {
        expect(s.quality, isNot(contains('/')));
        expect(s.quality, isNot(contains('·')));
      }
      VideoSource by(String quality, String audio) => data.firstWhere(
          (s) => s.quality == quality && s.audio == audio);
      expect(by('Auto', 'dublado').dashHeight, isNull);
      expect(by('Auto', 'legendado').dashHeight, isNull);
      expect(by('1080p', 'dublado').dashHeight, 1080);
      expect(by('720p', 'legendado').dashHeight, 720);
      // Mesma URL do manifesto em todas as entradas do mesmo áudio.
      expect(
          data
              .where((s) => s.audio == 'dublado')
              .map((s) => s.url)
              .toSet(),
          hasLength(1));
    });

    test('qualidade única → só a fixa (sem Auto redundante)', () async {
      final adapter = seasonAdapter(
        {
          's2e1': dashEpisodeJson(
            qualitiesDub: const ['480p'],
            qualitiesLeg: const ['480p'],
          )
        },
        seasonAnimeJson,
      );
      final vs = await adapter.getVideoSources(
        Episode(number: '3', url: 'https://api.animefire.io/episode/s2e1'),
      );
      final data = (vs as Success<List<VideoSource>>).data;
      expect(data.map((s) => s.quality), everyElement('480p'));
      expect(
          data.map((s) => s.audio), containsAll(['dublado', 'legendado']));
      expect(data.any((s) => s.quality.startsWith('Auto')), isFalse);
    });

    test('stream offline (url null) é descartado, dublado sobrevive', () async {
      final adapter = seasonAdapter(
        {
          's2e1': dashEpisodeJson(
            qualitiesDub: const ['480p'],
            qualitiesLeg: const ['480p'],
            legOffline: true,
          )
        },
        seasonAnimeJson,
      );
      final vs = await adapter.getVideoSources(
        Episode(number: '3', url: 'https://api.animefire.io/episode/s2e1'),
      );
      final data = (vs as Success<List<VideoSource>>).data;
      expect(data, hasLength(1));
      expect(data.single.url, 'https://akumast.net/i/dub/m.jpg');
      expect(data.single.quality, '480p');
      expect(data.single.audio, 'dublado');
      expect(data.single.dashHeight, 480);
    });

    test('gap na API: S2 sem E2 → resolveVideo(S2,2) → [] (não S2E3)',
        () async {
      // S2 published E1 (abs 3) and E3 (abs 5); per-season E2 is missing.
      // Positional match would silently serve S2E3; number matching yields [].
      const gapAnimeJson = '{"data":{"seasons":['
          '{"number":1,"first_episode_number":1},'
          '{"number":2,"first_episode_number":3}],'
          '"episodes":['
          '{"id":"s1e1","title":"E1","audio":"Dublado","season":1,"number":1},'
          '{"id":"s1e2","title":"E2","audio":"Dublado","season":1,"number":2},'
          '{"id":"s2e1","title":"E3","audio":"Dublado","season":2,"number":1},'
          '{"id":"s2e3","title":"E5","audio":"Dublado","season":2,"number":3}'
          ']}}';
      final adapter = seasonAdapter(
        {
          's2e1': dashEpisodeJson(
              qualitiesDub: const ['480p'], qualitiesLeg: const ['480p']),
          's2e3': dashEpisodeJson(
              qualitiesDub: const ['480p'], qualitiesLeg: const ['480p']),
        },
        gapAnimeJson,
      );
      final match = Anime(
          name: 'Black Clover',
          url: 'https://animefire.io/anime/bc789',
          source: AnimeSource.animeFire);
      final catalog = Anime(
          name: 'Black Clover 2nd Season',
          url: '',
          source: AnimeSource.anilist);
      expect(await adapter.resolveVideo(match, 2, catalog: catalog), isEmpty);
      // Neighbours still resolve: S2E1 (abs 3) and S2E3 (abs 5).
      expect(await adapter.resolveVideo(match, 1, catalog: catalog),
          isNotEmpty);
      expect(await adapter.resolveVideo(match, 3, catalog: catalog),
          isNotEmpty);
    });

    test('grade fallback rotula temporadas (AniList fora → absolutos)',
        () async {
      // Entry sem episodes (AniList 403): a grade vem do provider combinado
      // (absolutos 1..4) e cada linha carrega seu T — "EP 1 · T1" nunca lê
      // como S4E21.
      final adapter = seasonAdapter(const {}, seasonAnimeJson);
      final repo = AnimeRepository(adapters: [adapter]);
      final grid = await repo.getCatalogEpisodes(Anime(
          name: 'Black Clover Sem Enriquecimento',
          url: 'https://animefire.io/anime/bc789',
          source: AnimeSource.animeFire));
      expect(grid.map((e) => e.number).toList(), [1, 2, 3, 4]);
      expect(grid.map((e) => e.seasonLabel).toList(), ['T1', 'T1', 'T2', 'T2']);
    });

    test('grade saudável (AniList ok) não tem badges', () async {
      final adapter = seasonAdapter(const {}, seasonAnimeJson);
      final repo = AnimeRepository(adapters: [adapter]);
      final grid = await repo.getCatalogEpisodes(Anime(
          name: 'Black Clover Saudável',
          url: 'https://animefire.io/anime/bc789',
          source: AnimeSource.animeFire,
          episodes: 2));
      expect(grid.map((e) => e.number).toList(), [1, 2]);
      expect(grid.map((e) => e.seasonLabel).toList(), [isNull, isNull]);
    });
  });
}