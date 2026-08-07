import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';
import 'package:goanime_tv/core/sources/goyabu_adapter.dart';

/// Contract tests for the reviewed architecture:
///  - the canonical grid ([AnimeRepository.getCatalogEpisodes]) is pure
///    catalog (1..N, no provider url/source);
///  - the two new adapter verbs resolve on demand against the provider.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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

  test('resolveAnime + resolveVideo resolve episode N on the provider', () async {
    final adapter = GoyabuAdapter(
      client: MockClient((req) async {
        final host = req.url.host;
        if (host == 'goyabu.io' && req.url.path == '/') {
          // search result
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

    // A number the provider doesn't have resolves empty.
    expect(await adapter.resolveVideo(match, 99), isEmpty);
  });
}