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
}