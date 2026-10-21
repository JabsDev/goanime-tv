import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/sushi_animes_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

/// Contrato do Sushi Animes (sushianimes.com.br), verificado ao vivo em
/// 21/10/2026:
///  - a busca exige `_TOKEN` + cookie da home (POST /search);
///  - a grade vem em `.epx-card`, com temporada e número na URL;
///  - o player tem 2 `data-embed`: o primeiro é Blogger (morto), o segundo é
///    o CDN próprio (`var playerEmbed="…m3u8"`).
void main() {
  const base = 'https://sushianimes.com.br';

  String searchPage() => '''
<html><head><title>Você pesquisou por bleach</title></head><body>
<div class="list-movie">
  <a href="$base/anime/bleach-1105" class="list-media">
    <div class="media media-cover" data-src="$base/public/upload/cover/bleach.webp"></div>
  </a>
  <div class="list-caption">
    <a href="$base/anime/bleach-1105" class="list-title">Bleach</a>
  </div>
</div>
<div class="list-movie">
  <a href="$base/anime/bleach-dublado-777" class="list-media"></a>
  <div class="list-caption">
    <a href="$base/anime/bleach-dublado-777" class="list-title">Bleach Dublado</a>
  </div>
</div>
</body></html>
''';

  String animePage() => '''
<html><body>
<a class="epx-card" href="$base/anime/bleach-1105-1-season-1-episode" title="1º Episódio">
  <div class="epx-thumb" data-src="$base/thumb1.jpg"></div>
  <div class="epx-desc">O Dia Em Que Me Tornei Um Shinigami</div>
</a>
<a class="epx-card" href="$base/anime/bleach-1105-1-season-2-episode" title="2º Episódio">
  <div class="epx-desc">Segundo</div>
</a>
<a class="epx-card" href="$base/anime/bleach-1105-2-season-1-episode" title="1º Episódio">
  <div class="epx-desc">TYBW 1</div>
</a>
</body></html>
''';

  String episodePage(String embedId) => '''
<html><body>
<button class="btn-service" data-embed="111" data-player-name="Mobile">Mobile</button>
<button class="btn-service" data-embed="$embedId" data-player-name="FullHD / HLS">FullHD / HLS</button>
</body></html>
''';

  String bloggerEmbed() => '''
<iframe src="https://www.blogger.com/video.g?token=DEAD"></iframe>
''';

  String hlsEmbed(String url) => '''
<iframe srcdoc="&lt;script&gt;var playerEmbed=&quot;$url&quot;;&lt;/script&gt;"></iframe>
''';

  MockClient client() => MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('/search/')) {
          return http.Response(searchPage(), 200);
        }
        if (u.contains('/ajax/embed')) {
          if (req.body.contains('111')) {
            return http.Response(bloggerEmbed(), 200);
          }
          // O corpo real vem com srcdoc escapado; o id vem do data-embed da
          // página do episódio, não da URL do POST — o mock decide pelo
          // Referer.
          final ref = req.headers['Referer'] ?? req.headers['referer'] ?? '';
          final stream = ref.contains('2-season-1')
              ? '$base/cdn/s2.m3u8'
              : '$base/cdn/s1.m3u8';
          return http.Response(hlsEmbed(stream), 200);
        }
        if (u.contains('/anime/bleach-1105-2-season-1-episode')) {
          return http.Response(episodePage('222'), 200);
        }
        if (u.contains('/anime/bleach-1105-1-season-1-episode')) {
          return http.Response(episodePage('222'), 200);
        }
        if (u.contains('/anime/bleach-1105-1-season-2-episode')) {
          return http.Response(episodePage('111'), 200);
        }
        if (u.contains('/anime/bleach-1105')) {
          return http.Response(animePage(), 200);
        }
        if (u.endsWith('.m3u8')) {
          return http.Response('#EXTM3U\n#EXTINF:10,\nseg-1.webp\n', 200);
        }
        if (req.method == 'HEAD') {
          return http.Response('', 200);
        }
        return http.Response('not found', 404);
      });

  test('search: GET /search/<q> e parseia .list-movie', () async {
    final adapter = SushiAnimesAdapter(client: client());
    final result = await adapter.search('bleach');
    expect(result, isA<Success<List<Anime>>>());
    final list = (result as Success<List<Anime>>).data;
    expect(list.map((a) => a.name), containsAll(['Bleach', 'Bleach (Dublado)']));
    expect(list.first.url, '$base/anime/bleach-1105');
    expect(list.first.fallbackImageUrl, contains('bleach.webp'));
  });

  test('getEpisodes: temporada + número da URL, ordenado', () async {
    final adapter = SushiAnimesAdapter(client: client());
    final anime = Anime(
      name: 'Bleach',
      url: '$base/anime/bleach-1105',
      source: AnimeSource.sushiAnimes,
    );
    final result = await adapter.getEpisodes(anime);
    final eps = (result as Success<List<Episode>>).data;
    expect(eps.length, 3);
    expect(eps.map((e) => '${e.season}-${e.number}'),
        ['1-1', '1-2', '2-1']);
    expect(eps.last.title, 'TYBW 1');
  });

  test('getVideoSources: descarta o Blogger e aceita o CDN', () async {
    final adapter = SushiAnimesAdapter(client: client());
    final ep = Episode(
      number: '1',
      url: '$base/anime/bleach-1105-1-season-1-episode',
    );
    final result = await adapter.getVideoSources(ep);
    final sources = (result as Success<List<VideoSource>>).data;
    expect(sources, hasLength(1));
    expect(sources.first.url, '$base/cdn/s1.m3u8');
    expect(sources.first.quality, 'Auto');
  });

  test('resolveVideo: dica de temporada escolhe S2E1, não S1E1', () async {
    final adapter = SushiAnimesAdapter(client: client());
    final match = Anime(
      name: 'Bleach',
      url: '$base/anime/bleach-1105',
      source: AnimeSource.sushiAnimes,
    );
    final catalog = Anime(
      name: 'Bleach Season 2',
      url: 'anilist://2',
      source: AnimeSource.anilist,
    );
    final sources = await adapter.resolveVideo(match, 1, catalog: catalog);
    expect(sources, hasLength(1));
    expect(sources.first.url, '$base/cdn/s2.m3u8');
  });
}
