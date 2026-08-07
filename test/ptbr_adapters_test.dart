import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/goyabu_adapter.dart';
import 'package:goanime_tv/core/sources/dooplay_adapter.dart';
import 'package:goanime_tv/core/sources/animeplayer_adapter.dart';

/// Parsing self-checks for the PT-BR adapters. Feeds canned HTML (captured
/// from the live sites) through [MockClient] so no network is needed; fails
/// only if the regex/DOM parsing logic regresses.
void main() {
  Future<http.Response> searchPage() async => http.Response(
        '''
<html><body>
<article class="boxAN">
  <a href="https://goyabu.io/anime/one-piece" class="cover">
    <img class="cover" src="https://goyabu.io/cap/op.jpg" alt="One Piece">
  </a>
</article>
<article class="boxAN">
  <a href="https://goyabu.io/anime/naruto">
    <img class="cover" src="x.jpg" alt="Naruto">
  </a>
</article>
</body></html>
''',
        200,
        headers: {'content-type': 'text/html'},
      );

  test('Goyabu search parses .boxAN cards', () async {
    final adapter = GoyabuAdapter(client: MockClient((req) async {
      expect(req.url.path, '/');
      expect(req.url.queryParameters['s'], 'naruto');
      return searchPage();
    }));
    final result = await adapter.search('naruto');
    expect(result, isA<Success<List<Anime>>>());
    final data = (result as Success<List<Anime>>).data;
    expect(data.length, 2);
    expect(data[0].name, 'One Piece');
    expect(data[0].url, 'https://goyabu.io/anime/one-piece');
    expect(data[0].fallbackImageUrl, 'https://goyabu.io/cap/op.jpg');
  });

  test('DooPlay search parses .result-item cards', () async {
    final adapter = DooPlayAdapter(
      source: AnimeSource.dooPlay,
      client: MockClient((req) async {
        expect(req.url.queryParameters['s'], 'naruto');
        return http.Response(
          '''
<html><body>
<div class="result-item">
  <article>
    <div class="image">
      <a href="https://betteranime.io/animes/naruto/">
        <img src="/cap/naruto.jpg" alt="Naruto">
      </a>
    </div>
  </article>
</div>
</body></html>
''',
          200,
        );
      }),
    );
    final result = await adapter.search('naruto');
    expect(result, isA<Success<List<Anime>>>());
    final data = (result as Success<List<Anime>>).data;
    expect(data.single.name, 'Naruto');
    expect(data.single.url, 'https://betteranime.io/animes/naruto/');
  });

  test('DooPlay getEpisodes parses /episodios/ links ordered', () async {
    final adapter = DooPlayAdapter(
      source: AnimeSource.dooPlay,
      client: MockClient((req) async {
        if (req.url.host == 'betteranime.io' && req.url.path.contains('/animes/')) {
          return http.Response(
            '''
<html><body>
<a href="https://betteranime.io/episodios/op-episodio-3/">Ep 3</a>
<a href="https://betteranime.io/episodios/op-episodio-10/">Ep 10</a>
<a href="https://betteranime.io/episodios/op-episodio-2/">Ep 2</a>
</body></html>
''',
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    final result = await adapter.getEpisodes(
      Anime(name: 'Op', url: 'https://betteranime.io/animes/op/'),
    );
    expect(result, isA<Success<List<Episode>>>());
    final eps = (result as Success<List<Episode>>).data;
    expect(eps.map((e) => int.parse(e.number)).toList(), [2, 3, 10]);
    expect(eps.last.number, '10');
  });

  test('AnimePlayer search parses .result-item cards', () async {
    final adapter = AnimePlayerAdapter(
      client: MockClient((req) async {
        expect(req.url.queryParameters['s'], 'naruto');
        return http.Response(
          '''
<html><body>
<div class="result-item">
  <article>
    <div class="image">
      <a href="https://animeplayer.com.br/animes/naruto/">
        <img src="/cap/naruto.jpg" alt="Naruto">
      </a>
    </div>
  </article>
</div>
</body></html>
''',
          200,
        );
      }),
    );
    final result = await adapter.search('naruto');
    expect(result, isA<Success<List<Anime>>>());
    final data = (result as Success<List<Anime>>).data;
    expect(data.single.name, 'Naruto');
    expect(data.single.source, AnimeSource.animePlayer);
    expect(adapter.implemented, isTrue);
  });
}