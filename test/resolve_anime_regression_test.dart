import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/anime_fire_adapter.dart';
import 'package:goanime_tv/core/sources/anime_source_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';
import 'package:goanime_tv/core/storage/provider_match_store.dart';

/// Offline regression for the reported "One Piece" failure, using the
/// AnimeFire JSON API payload shape (`GET /animes/pesquisar?q=`). No network.
String searchJson() => '''
{"data":[
  {"id":"koi123","title":"Koisuru One Piece","audio":"Legendado",
   "poster_src":"https://image.tmdb.org/t/p/original/koi.webp",
   "status":"completed","published_at":"2022-01-01"},
  {"id":"op456","title":"One Piece","audio":"Dublado \\u0026 Legendado",
   "poster_src":"https://image.tmdb.org/t/p/original/op.webp",
   "status":"airing","published_at":"1999-10-20"}
]}
''';

/// Fake adapter: search returns the spin-off first, but the series page is
/// what delivers video. Used to prove the resolution flow persists only the
/// page that actually yields a source.
class _FakeAdapter extends AnimeSourceAdapter {
  _FakeAdapter(this._episodeOk);

  final bool _episodeOk;

  @override
  AnimeSource get source => AnimeSource.animeFire;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    return ScraperResult.success([
      Anime(
        name: 'Koisuru One Piece',
        url: 'https://animefire.io/animes/koisuru-one-piece-todos-os-episodios',
        source: AnimeSource.animeFire,
      ),
      Anime(
        name: 'One Piece',
        url: 'https://animefire.io/animes/one-piece-todos-os-episodios',
        source: AnimeSource.animeFire,
      ),
    ]);
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    return ScraperResult.success([
      Episode(number: '1', url: '${anime.url}/ep-1', owner: anime),
    ]);
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    return AvailabilityReport(source: source, animeName: animeName);
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    if (!_episodeOk) {
      return ScraperResult.failure(const EmptyResultError(
        message: 'no source',
        source: AnimeSource.animeFire,
      ));
    }
    return ScraperResult.success([
      VideoSource(
        url: 'https://cdn.example.com/ep1.m3u8',
        quality: 'Auto',
      ),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('resolveAnime maps "One Piece" to the main series, not the spin-off',
      () async {
    final adapter = AnimeFireAdapter(
      client: MockClient((req) async => http.Response(searchJson(), 200)),
    );
    final match = await adapter.resolveAnime(
      Anime(name: 'One Piece', url: '', source: AnimeSource.animeFire),
    );
    expect(match, isNotNull);
    expect(match!.url, 'https://animefire.io/anime/op456');
    expect(match.name, 'One Piece');
  });

  test('persistência: página que entrega o ep é salva no ProviderMatchStore',
      () async {
    final repo = AnimeRepository(adapters: [_FakeAdapter(true)]);
    final anime = Anime(name: 'One Piece', url: '', source: AnimeSource.animeFire);
    final results = await repo.resolveProvidersForEpisode(anime, 1);
    expect(results.providers[AnimeSource.animeFire], isNotEmpty);
    final url = await ProviderMatchStore.urlFor(
      ProviderMatchStore.identity(anime),
      AnimeSource.animeFire,
    );
    expect(url, 'https://animefire.io/animes/one-piece-todos-os-episodios');
  });

  test('persistência: 0 fontes → matchedUnavailable sem remover o match',
      () async {
    final anime = Anime(name: 'One Piece Stale', url: '', source: AnimeSource.animeFire);
    final identity = ProviderMatchStore.identity(anime);
    // Stale persisted match from the old buggy discovery (the spin-off).
    await ProviderMatchStore.saveMatch(
      identity,
      AnimeSource.animeFire,
      'https://animefire.io/animes/koisuru-one-piece-todos-os-episodios',
    );

    final repo = AnimeRepository(adapters: [_FakeAdapter(false)]);
    final results = await repo.resolveProvidersForEpisode(anime, 1);
    expect(results.providers, isEmpty);
    expect(results.matchedUnavailable, contains(AnimeSource.animeFire));
    // P4: página casou, extração falhou → o match persistido é MANTIDO para o
    // próximo toque não re-pagar a busca.
    expect(await ProviderMatchStore.urlFor(identity, AnimeSource.animeFire),
        'https://animefire.io/animes/koisuru-one-piece-todos-os-episodios');
  });

  test('2nd resolve reuses persisted match (no re-search) only when it delivers',
      () async {
    final repo = AnimeRepository(adapters: [_FakeAdapter(true)]);
    final anime = Anime(name: 'One Piece', url: '', source: AnimeSource.animeFire);
    final first = await repo.resolveProvidersForEpisode(anime, 1);
    expect(first.providers[AnimeSource.animeFire], isNotEmpty);
    final second = await repo.resolveProvidersForEpisode(anime, 1);
    expect(second.providers[AnimeSource.animeFire], isNotEmpty);
  });

  test('grid RELEASING: catalog without episode total falls back to provider count',
      () async {
    final repo = AnimeRepository(adapters: [_FakeAdapter(true)]);
    final anime = Anime(
      name: 'One Piece',
      url: '',
      source: AnimeSource.animeFire,
      anilistId: 21,
      episodes: null, // AniList RELEASING series report no total.
    );
    final grid = await repo.getCatalogEpisodes(anime);
    expect(grid.length, 1); // _FakeAdapter.getEpisodes serves 1 episode.
    expect(grid.first.number, 1);
  });
}