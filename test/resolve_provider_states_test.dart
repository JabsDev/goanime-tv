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

const _searchHtml =
    '<div class="row ml-1 mr-1"><a href="/animes/black-clover-todos-os-episodios">'
    '<img class="imgAnimes" data-src="/uploads/bc.jpg"><span>Black Clover</span>'
    '</a></div>';

const _episodesHtml =
    '<a class="lEp epT divNumEp smallbox px-2 mx-1 text-left d-flex" '
    'href="/animes/black-clover/1">1</a>';

/// Blogger SPA page: only an iframe pointing at the anti-bot player.
const _bloggerSpaHtml =
    '<html><body><iframe src="https://www.blogger.com/video.g?token=abc123">'
    '</iframe></body></html>';

const _playableHtml =
    '<div data-video-src="https://cdn.example.com/720.mp4" data-quality="720p">'
    '</div>';

AnimeFireAdapter _adapter(String episodeHtml, {void Function()? onSearch}) {
  return AnimeFireAdapter(
    client: MockClient((req) async {
      final path = req.url.path;
      if (path.startsWith('/pesquisar/')) {
        onSearch?.call();
        return http.Response(_searchHtml, 200);
      }
      if (path.endsWith('todos-os-episodios')) {
        return http.Response(_episodesHtml, 200);
      }
      if (path.contains('/animes/black-clover/')) {
        return http.Response(episodeHtml, 200);
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
  Future<List<VideoSource>> resolveVideo(
      Anime match, int episodeNumber) async {
    await Future.delayed(delay);
    return super.resolveVideo(match, episodeNumber);
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

  test('página achada + extração vazia (Blogger SPA) → matchedUnavailable',
      () async {
    final repo = AnimeRepository(adapters: [_adapter(_bloggerSpaHtml)]);
    final res = await repo.resolveProvidersForEpisode(_anime(id: 21), 1);

    expect(res.providers, isEmpty);
    expect(res.notFound, isEmpty);
    expect(res.matchedUnavailable, contains(AnimeSource.animeFire));
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
    const url = 'https://animefire.io/animes/black-clover-todos-os-episodios';
    await ProviderMatchStore.saveMatch(
        identity, AnimeSource.animeFire, url);

    var searches = 0;
    final repo =
        AnimeRepository(adapters: [_adapter(_bloggerSpaHtml, onSearch: () => searches++)]);
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

  test('página achada + vídeo ok → providers e match persistido', () async {
    final repo = AnimeRepository(adapters: [_adapter(_playableHtml)]);
    final anime = _anime(id: 24);
    final res = await repo.resolveProvidersForEpisode(anime, 1);

    expect(res.matchedUnavailable, isEmpty);
    expect(res.providers[AnimeSource.animeFire], isNotEmpty);
    expect(res.providers[AnimeSource.animeFire]!.first.url,
        'https://cdn.example.com/720.mp4');
    expect(
        await ProviderMatchStore.urlFor(
            ProviderMatchStore.identity(anime), AnimeSource.animeFire),
        isNotNull);
  });

  test('getVideoSources classifica Blogger SPA como BloggerUnsupportedError',
      () async {
    final adapter = _adapter(_bloggerSpaHtml);
    final vs = await adapter.getVideoSources(
      Episode(
        number: '1',
        url: 'https://animefire.io/animes/black-clover/1',
        owner: _anime(id: 1),
      ),
    );
    expect(vs, isA<Failure<List<VideoSource>>>());
    final err = ((vs as Failure).error);
    expect(err, isA<BloggerUnsupportedError>());
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
}