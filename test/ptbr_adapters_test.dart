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

  // Goyabu Slime S4 (relatorio-slime-s4e21 §4b, probe 11/09/2026): the S4
  // page holds only 19 eps (update 21/08/2026) — E20/E21/E22 don't exist
  // there, so EP21 must classify as matchedUnavailable ([]), never as a
  // wrong-season video. E19 still resolves.
  group('Goyabu S4 curta (19 eps)', () {
    String s4ShortPage() {
      final eps = List.generate(
        19,
        (i) =>
            '{"id":${50800 + i},"episodio":"${i + 1}","link":"/${50800 + i}","episode_name":"E${i + 1}"}',
      ).join(',');
      return '<html><body><script>var allEpisodes = [$eps];</script></body></html>';
    }

    GoyabuAdapter s4Adapter() => GoyabuAdapter(
          client: MockClient((req) async {
            if (req.url.path.startsWith('/anime/')) {
              return http.Response(s4ShortPage(), 200,
                  headers: {'content-type': 'text/html'});
            }
            // Episode page with a recoverable HLS layer.
            return http.Response(
              '<html><body><script>var layersData = [{"url":"https://api.anivideo.fun/videohls.php?d=ep${req.url.pathSegments.last}.m3u8"}];</script></body></html>',
              200,
              headers: {'content-type': 'text/html'},
            );
          }),
        );

    Anime s4Match() => Anime(
          name: 'Slime S4',
          url: 'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-4',
          source: AnimeSource.goyabu,
        );
    Anime s4Catalog() => Anime(
          name: 'Tensei Shitara Slime Datta Ken 4th Season',
          url: '',
          source: AnimeSource.anilist,
        );

    test('getEpisodes lists 19 (E20/E21 ausentes no site)', () async {
      final result = await s4Adapter().getEpisodes(s4Match());
      expect(result, isA<Success<List<Episode>>>());
      final eps = (result as Success<List<Episode>>).data;
      expect(eps.length, 19);
      expect(eps.map((e) => e.number), contains('19'));
      expect(eps.map((e) => e.number), isNot(contains('21')));
    });

    test('resolveVideo(S4, 21) → [] (matchedUnavailable honesto)', () async {
      expect(await s4Adapter().resolveVideo(s4Match(), 21, catalog: s4Catalog()),
          isEmpty);
    });

    test('resolveVideo(S4, 19) → OK', () async {
      final sources =
          await s4Adapter().resolveVideo(s4Match(), 19, catalog: s4Catalog());
      expect(sources.map((s) => s.url),
          contains('https://api.anivideo.fun/videohls.php?d=ep50818.m3u8'));
    });
  });

  // AnimePlayer season-aware: `-SxE` slugs on a combined page used to
  // collapse (`2x1` → 1, same limitation as DooPlay). Episode pages carry a
  // plain .mp4 here so the mock stays one step.
  group('AnimePlayer season-aware (combined -SxE page)', () {
    const animePage = '''
<html><body>
<a href="https://animeplayer.com.br/episodios/slime-1x21/">S1E21</a>
<a href="https://animeplayer.com.br/episodios/slime-2x21/">S2E21</a>
</body></html>
''';

    AnimePlayerAdapter playerAdapter() => AnimePlayerAdapter(
          client: MockClient((req) async {
            final path = req.url.path;
            if (path.contains('/animes/')) {
              return http.Response(animePage, 200);
            }
            final m =
                RegExp(r'slime-(\d+)x(\d+)').firstMatch(path);
            final tag = m == null ? 's1x0' : 's${m.group(1)}x${m.group(2)}';
            return http.Response(
              '<html><body><video src="https://cdn.example.com/slime/$tag.mp4"></video></body></html>',
              200,
            );
          }),
        );

    Anime playerMatch() => Anime(
          name: 'Slime',
          url: 'https://animeplayer.com.br/animes/slime/',
          source: AnimeSource.animePlayer,
        );

    test('seasonEpisode parses -SxE with season', () {
      expect(
          AnimePlayerAdapter.seasonEpisode(
              'https://animeplayer.com.br/episodios/slime-2x21/'),
          (2, 21));
      expect(
          AnimePlayerAdapter.seasonEpisode(
              'https://animeplayer.com.br/episodios/naruto-1x10/'),
          (1, 10));
    });

    test('resolveVideo(S2, 21) → S2E21 (was S1E21)', () async {
      final sources = await playerAdapter().resolveVideo(
        playerMatch(),
        21,
        catalog: Anime(
            name: 'Tensei Shitara Slime Datta Ken 2nd Season',
            url: '',
            source: AnimeSource.anilist),
      );
      expect(sources.map((s) => s.url),
          contains('https://cdn.example.com/slime/s2x21.mp4'));
    });
  });
}