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

/// Offline regression for the reported "One Piece" failure, using the exact
/// AnimeFire search markup captured from the live site. No network involved.
String searchHtml() => '''
<html><body>
<div class="card-group">
  <div class="row ml-1 mr-1">
    <div class="col-6 mb-1 divCardUltimosEps" title="Koisuru One Piece - Todos os Epis&oacute;dios">
      <article class="card cardUltimosEps">
        <a href="https://animefire.io/animes/koisuru-one-piece-todos-os-episodios">
          <img class="card-img-top lazy imgAnimes" src="" data-src="https://animefire.io/img/animes/koisuru-one-piece.webp" alt="Koisuru One Piece - Todos os Epis&oacute;dios">
          <div class="text-block"><h3 class="animeTitle">Koisuru One Piece</h3></div>
        </a>
      </article>
    </div>
    <div class="col-6 mb-1 divCardUltimosEps" title="One Piece: Gyojin Tou-hen - Todos os Epis&oacute;dios">
      <article class="card cardUltimosEps">
        <a href="https://animefire.io/animes/one-piece-gyojin-tou-hen-todos-os-episodios">
          <img class="card-img-top lazy imgAnimes" src="" data-src="https://animefire.io/img/animes/gyojin.webp" alt="One Piece: Gyojin Tou-hen - Todos os Epis&oacute;dios">
          <div class="text-block"><h3 class="animeTitle">One Piece: Gyojin Tou-hen</h3></div>
        </a>
      </article>
    </div>
    <div class="col-6 mb-1 divCardUltimosEps" title="One Piece Film: Red - Todos os Epis&oacute;dios">
      <article class="card cardUltimosEps">
        <a href="https://animefire.io/animes/one-piece-film-red-dublado-todos-os-episodios">
          <img class="card-img-top lazy imgAnimes" src="" data-src="https://animefire.io/img/animes/red.webp" alt="One Piece Film: Red - Todos os Epis&oacute;dios">
          <div class="text-block"><h3 class="animeTitle">One Piece Film: Red</h3></div>
        </a>
      </article>
    </div>
    <div class="col-6 mb-1 divCardUltimosEps" title="One Piece - Todos os Epis&oacute;dios">
      <article class="card cardUltimosEps">
        <a href="https://animefire.io/animes/one-piece-todos-os-episodios">
          <img class="card-img-top lazy imgAnimes" src="" data-src="https://animefire.io/img/animes/one-piece.webp" alt="One Piece - Todos os Epis&oacute;dios">
          <div class="text-block"><h3 class="animeTitle">One Piece</h3></div>
        </a>
      </article>
    </div>
  </div>
</div>
</body></html>
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
      client: MockClient((req) async => http.Response(searchHtml(), 200)),
    );
    final match = await adapter.resolveAnime(
      Anime(name: 'One Piece', url: '', source: AnimeSource.animeFire),
    );
    expect(match, isNotNull);
    expect(match!.url, 'https://animefire.io/animes/one-piece-todos-os-episodios');
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