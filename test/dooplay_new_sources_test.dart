// Parsing self-checks for the newly integrated DooPlay-family sources:
// Animes Online HDK, Animes Orion and AnimesHD. All three share the DooPlay
// WordPress theme but differ in catalog path, episode URL scheme and player
// transport — the refactored [DooPlayAdapter] must route each correctly.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/dooplay_adapter.dart';
import 'package:goanime_tv/core/sources/source_registry.dart';

http.Response _ok(String body, {int status = 200}) =>
    http.Response(body, status, headers: {'content-type': 'text/html'});

http.Response _json(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

http.Response _probe() => http.Response(
      'x',
      206,
      headers: {'content-range': 'bytes 0-0/125505938'},
    );

/// HDK search results live under `/tvshows/`.
const _hdkSearch = '''
<html><body>
<div class="result-item"><article>
  <div class="image"><div class="thumbnail animation-2">
    <a href="https://animesonlinehdk.com/tvshows/naruto-shippuden/">
      <img src="https://animesonlinehdk.com/wp-content/uploads/2023/10/a-150x150.jpg" alt="Naruto Shippuden" />
      <span class="tvshows">TV</span>
    </a>
  </div></div>
  <div class="details"><div class="title"><a href="https://animesonlinehdk.com/tvshows/naruto-shippuden/">Naruto Shippuden</a></div></div>
</article></div>
<div class="result-item"><article>
  <div class="image"><div class="thumbnail animation-2">
    <a href="https://animesonlinehdk.com/tvshows/naruto/">
      <img src="https://animesonlinehdk.com/wp-content/uploads/2024/11/b-150x150.jpg" alt="Naruto" />
      <span class="tvshows">TV</span>
    </a>
  </div></div>
</article></div>
</body></html>
''';

/// HDK anime page: episodes under `/episodes/` with `-<s>x<n>/` URLs.
const _hdkAnime = '''
<html><body>
<div class='se-c'><div class='se-a' style="display:block"><ul class='episodios'>
<li class='mark-1'><div class='imagen'><img src='x.jpg'></div><div class='numerando'>1 - 1</div><div class='episodiotitle'><a href='https://animesonlinehdk.com/episodes/naruto-1x1/'>Naruto Uzumaki Chegando!</a></div></li>
<li class='mark-10'><div class='imagen'><img src='x.jpg'></div><div class='numerando'>1 - 10</div><div class='episodiotitle'><a href='https://animesonlinehdk.com/episodes/naruto-1x10/'>Um Clone, um Clone, e mais um Clone!</a></div></li>
<li class='mark-2'><div class='imagen'><img src='x.jpg'></div><div class='numerando'>1 - 2</div><div class='episodiotitle'><a href='https://animesonlinehdk.com/episodes/naruto-1x2/'>Meu Nome é Konohamaru!</a></div></li>
</ul></div></div>
</body></html>
''';

/// HDK episode page: `wp_json` transport.
const _hdkEpisode = '''
<html><body>
<div id='player-option-1' class='dooplay_player_option' data-type='tv' data-post='20915' data-nume='1'><i class='fas fa-play-circle'></i></div>
<script>dtAjax = {"url":"\\/wp-admin\\/admin-ajax.php","player_api":"https:\\/\\/animesonlinehdk.com\\/wp-json\\/dooplayer\\/v2\\/","play_method":"wp_json","loading":"Loading.."};</script>
</body></html>
''';

/// Orion search results live under `/animes/`.
const _orionSearch = '''
<html><body>
<div class="result-item"><article>
  <div class="image"><div class="thumbnail animation-2">
    <a href="https://animesorion.cc/animes/naruto-shippuden/">
      <img src="https://image.tmdb.org/t/p/w92/p.jpg" alt="Naruto Shippuden" />
      <span class="tvshows">Anime</span>
    </a>
  </div></div>
  <div class="details"><div class="title"><a href="https://animesorion.cc/animes/naruto-shippuden/">Naruto Shippuden</a></div></div>
</article></div>
</body></html>
''';

/// Orion anime page: episodes under `/episodios/` with `-<s>x<n>/` URLs.
const _orionAnime = '''
<html><body>
<ul class='episodios'>
<li class='mark-1'><div class='numerando'>1 - 1</div><div class='episodiotitle'><a href='https://animesorion.cc/episodios/naruto-shippuden-1x1/'>Voltando Para Casa</a></div></li>
<li class='mark-3'><div class='numerando'>1 - 3</div><div class='episodiotitle'><a href='https://animesorion.cc/episodios/naruto-shippuden-1x3/'>Resultado do Treinamento</a></div></li>
<li class='mark-2'><div class='numerando'>1 - 2</div><div class='episodiotitle'><a href='https://animesorion.cc/episodios/naruto-shippuden-1x2/'>Os Akatsuki Entram em Ação</a></div></li>
</ul>
</body></html>
''';

/// Orion episode page: `admin_ajax` transport.
const _orionEpisode = '''
<html><body>
<div id='player-option-1' class='dooplay_player_option' data-type='tv' data-post='4781' data-nume='1'></div>
<script>dtAjax = {"url":"/wp-admin/admin-ajax.php","player_api":"https://animesorion.cc/wp-json/dooplayer/v2/","play_method":"admin_ajax","loading":"Loading.."};</script>
</body></html>
''';

/// AnimesHD search results live under `/animes/`.
const _ahdSearch = '''
<html><body>
<div class="result-item"><article><div class="image"><div class="thumbnail animation-2">
  <a href="https://animeshd.to/animes/naruto-shippuden-online-hd/">
    <img src="https://animeshd.to/wp-content/uploads/2024/11/c-150x150.jpg" alt="Naruto Shippuden" />
    <span class="tvshows"> ANIME </span>
  </a>
</div></div><div class="details"><div class="title">
  <a href="https://animeshd.to/animes/naruto-shippuden-online-hd/">Naruto Shippuden</a>
</div></div></article></div>
</body></html>
''';

/// AnimesHD anime page: episodes under `/episodios/` with `-episodio-<n>/`.
const _ahdAnime = '''
<html><body>
<ul class='episodios'>
<li class='mark-1'><div class='numerando'>1 - 1</div><div class='episodiotitle'><a href='https://animeshd.to/episodios/naruto-shippuden-episodio-1/'>Entrada em Ação</a></div></li>
<li class='mark-2'><div class='numerando'>1 - 2</div><div class='episodiotitle'><a href='https://animeshd.to/episodios/naruto-shippuden-episodio-2/'>Os Akatsuki</a></div></li>
<li class='mark-10'><div class='numerando'>1 - 10</div><div class='episodiotitle'><a href='https://animeshd.to/episodios/naruto-shippuden-episodio-10/'>Selamento</a></div></li>
</ul>
</body></html>
''';

/// AnimesHD episode page: NO `dtAjax` blob → wp-json probe then admin_ajax.
const _ahdEpisode = '''
<html><body>
<div id='player-option-1' class='dooplay_player_option' data-type='tv' data-post='4725' data-nume='1'></div>
</body></html>
''';

void main() {
  group('Animes Online HDK (wp_json, /tvshows/, /episodes/)', () {
    test('search parses .result-item filtered to /tvshows/', () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesOnlineHdk,
        client: MockClient((req) async {
          expect(req.url.queryParameters['s'], 'naruto');
          return _ok(_hdkSearch);
        }),
      );
      final result = await adapter.search('naruto');
      expect(result, isA<Success<List<Anime>>>());
      final data = (result as Success<List<Anime>>).data;
      expect(data.map((a) => a.name).toList(), ['Naruto Shippuden', 'Naruto']);
      expect(data.first.url, 'https://animesonlinehdk.com/tvshows/naruto-shippuden/');
      expect(data.first.source, AnimeSource.animesOnlineHdk);
    });

    test('getEpisodes parses -1xN URLs ordered (1,2,10)', () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesOnlineHdk,
        client: MockClient((req) async => _ok(_hdkAnime)),
      );
      final result = await adapter.getEpisodes(Anime(
        name: 'Naruto',
        url: 'https://animesonlinehdk.com/tvshows/naruto/',
      ));
      expect(result, isA<Success<List<Episode>>>());
      final eps = (result as Success<List<Episode>>).data;
      expect(eps.map((e) => int.parse(e.number)).toList(), [1, 2, 10]);
      expect(eps.first.url, 'https://animesonlinehdk.com/episodes/naruto-1x1/');
    });

    test('getVideoSources wp_json → blogger embed → graceful Failure', () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesOnlineHdk,
        client: MockClient((req) async {
          if (req.url.path == '/episodes/naruto-1x1/') {
            return _ok(_hdkEpisode);
          }
          if (req.url.path.startsWith('/wp-json/dooplayer/v2/20915/')) {
            return _json(
                '{"embed_url":"https://www.blogger.com/video.g?token=AD6v5TEST","type":"iframe"}');
          }
          // The blogger SPA page has no direct mp4/m3u8.
          if (req.url.host == 'www.blogger.com') {
            return _ok('<html><body><div id="video">SPA</div></body></html>');
          }
          return http.Response('nf', 404);
        }),
      );
      final result = await adapter.getVideoSources(
        Episode(number: '1', url: 'https://animesonlinehdk.com/episodes/naruto-1x1/'),
        anime: Anime(name: 'Naruto', url: 'https://animesonlinehdk.com/tvshows/naruto/'),
      );
      expect(result, isA<Failure<List<VideoSource>>>());
    });
  });

  group('Animes Orion (admin_ajax, /animes/, /episodios/ -NxM)', () {
    test('search parses .result-item under /animes/', () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesOrion,
        client: MockClient((req) async {
          expect(req.url.queryParameters['s'], 'naruto');
          return _ok(_orionSearch);
        }),
      );
      final result = await adapter.search('naruto');
      expect(result, isA<Success<List<Anime>>>());
      final data = (result as Success<List<Anime>>).data;
      expect(data.single.name, 'Naruto Shippuden');
      expect(data.single.url, 'https://animesorion.cc/animes/naruto-shippuden/');
    });

    test('getEpisodes parses -1xN URLs ordered (1,2,3)', () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesOrion,
        client: MockClient((req) async => _ok(_orionAnime)),
      );
      final result = await adapter.getEpisodes(Anime(
        name: 'Naruto Shippuden',
        url: 'https://animesorion.cc/animes/naruto-shippuden/',
      ));
      expect(result, isA<Success<List<Episode>>>());
      final eps = (result as Success<List<Episode>>).data;
      expect(eps.map((e) => int.parse(e.number)).toList(), [1, 2, 3]);
      expect(eps.first.url, 'https://animesorion.cc/episodios/naruto-shippuden-1x1/');
    });

    test('getVideoSources admin_ajax transport → direct mp4 (probe 206)',
        () async {
      const direct =
          'https://cdn.example.com/Animes/Letra-N/Naruto%20Shippuden/01.mp4';
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesOrion,
        client: MockClient((req) async {
          if (req.url.path == '/episodios/naruto-shippuden-1x1/') {
            return _ok(_orionEpisode);
          }
          if (req.url.path == '/wp-admin/admin-ajax.php') {
            expect(req.method, 'POST');
            expect(req.body, contains('action=doo_player_ajax'));
            expect(req.body, contains('post=4781'));
            expect(req.body, contains('nume=1'));
            return _json(
                '{"embed_url":"https://animesorion.cc/jwplayer?source=https%3A%2F%2Fcdn.example.com%2FAnimes%2FLetra-N%2FNaruto%2520Shippuden%2F01.mp4&id=4781&type=mp4","type":"mp4"}');
          }
          if (req.url.path.endsWith('.mp4')) return _probe();
          return http.Response('nf', 404);
        }),
      );
      final result = await adapter.getVideoSources(
        Episode(number: '1', url: 'https://animesorion.cc/episodios/naruto-shippuden-1x1/'),
        anime: Anime(name: 'Naruto Shippuden', url: 'https://animesorion.cc/animes/naruto-shippuden/'),
      );
      expect(result, isA<Success<List<VideoSource>>>());
      final sources = (result as Success<List<VideoSource>>).data;
      expect(sources.single.url, direct);
      expect(sources.single.headers['Referer'], 'https://animesorion.cc/');
    });

    test('getVideoSources admin_ajax → blogger embed → graceful Failure',
        () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesOrion,
        client: MockClient((req) async {
          if (req.url.path == '/episodios/naruto-shippuden-1x1/') {
            return _ok(_orionEpisode);
          }
          if (req.url.path == '/wp-admin/admin-ajax.php') {
            return _json(
                '{"embed_url":"https://www.blogger.com/video.g?token=AD6v5TEST","type":"iframe"}');
          }
          if (req.url.host == 'www.blogger.com') {
            return _ok('<html><body>SPA</body></html>');
          }
          return http.Response('nf', 404);
        }),
      );
      final result = await adapter.getVideoSources(
        Episode(number: '1', url: 'https://animesorion.cc/episodios/naruto-shippuden-1x1/'),
      );
      expect(result, isA<Failure<List<VideoSource>>>());
    });
  });

  group('AnimesHD (no dtAjax → admin_ajax fallback, /episodio-N/)', () {
    test('search parses .result-item under /animes/', () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesHd,
        client: MockClient((req) async {
          expect(req.url.queryParameters['s'], 'naruto');
          return _ok(_ahdSearch);
        }),
      );
      final result = await adapter.search('naruto');
      expect(result, isA<Success<List<Anime>>>());
      final data = (result as Success<List<Anime>>).data;
      expect(data.single.name, 'Naruto Shippuden');
      expect(data.single.url, 'https://animeshd.to/animes/naruto-shippuden-online-hd/');
    });

    test('getEpisodes parses -episodio-N URLs ordered (1,2,10)', () async {
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesHd,
        client: MockClient((req) async => _ok(_ahdAnime)),
      );
      final result = await adapter.getEpisodes(Anime(
        name: 'Naruto Shippuden',
        url: 'https://animeshd.to/animes/naruto-shippuden-online-hd/',
      ));
      expect(result, isA<Success<List<Episode>>>());
      final eps = (result as Success<List<Episode>>).data;
      expect(eps.map((e) => int.parse(e.number)).toList(), [1, 2, 10]);
      expect(eps.first.url, 'https://animeshd.to/episodios/naruto-shippuden-episodio-1/');
    });

    test('getVideoSources wp-json 404 → admin_ajax blogger → Failure', () async {
      var adminAjaxCalls = 0;
      final adapter = DooPlayAdapter(
        source: AnimeSource.animesHd,
        client: MockClient((req) async {
          if (req.url.path == '/episodios/naruto-shippuden-episodio-1/') {
            return _ok(_ahdEpisode);
          }
          if (req.url.path.startsWith('/wp-json/dooplayer/v2/')) {
            return http.Response('nf', 404);
          }
          if (req.url.path == '/wp-admin/admin-ajax.php') {
            adminAjaxCalls++;
            return _json(
                '{"embed_url":"https://www.blogger.com/video.g?token=AD6v5TEST","type":"iframe"}');
          }
          if (req.url.host == 'www.blogger.com') {
            return _ok('<html><body>SPA</body></html>');
          }
          return http.Response('nf', 404);
        }),
      );
      final result = await adapter.getVideoSources(
        Episode(number: '1', url: 'https://animeshd.to/episodios/naruto-shippuden-episodio-1/'),
      );
      expect(result, isA<Failure<List<VideoSource>>>());
      expect(adminAjaxCalls, 1,
          reason: 'admin_ajax é o fallback quando o wp-json não responde');
    });
  });

  group('DooPlay family wiring', () {
    test('registry routes every new source to its own DooPlayAdapter', () {
      for (final s in [
        AnimeSource.animesOnlineHdk,
        AnimeSource.animesOrion,
        AnimeSource.animesHd,
      ]) {
        final adapter = SourceRegistry.forSource(s);
        expect(adapter, isA<DooPlayAdapter>(),
            reason: '$s deve rotear para um DooPlayAdapter');
        expect(adapter.source, s);
        expect(adapter.implemented, isTrue);
      }
      expect(DooPlayAdapter.baseUrls[AnimeSource.animesOnlineHdk],
          'https://animesonlinehdk.com');
      expect(DooPlayAdapter.baseUrls[AnimeSource.animesOrion],
          'https://animesorion.cc');
      expect(DooPlayAdapter.baseUrls[AnimeSource.animesHd], 'https://animeshd.to');
    });

    test('enum metadata: sourceName, isPtBr and display priority', () {
      expect(
          Anime(name: '', url: '', source: AnimeSource.animesOnlineHdk).sourceName,
          'Animes Online HDK');
      expect(Anime(name: '', url: '', source: AnimeSource.animesOrion).sourceName,
          'Animes Orion');
      expect(Anime(name: '', url: '', source: AnimeSource.animesHd).sourceName,
          'AnimesHD');
      for (final s in [
        AnimeSource.animesOnlineHdk,
        AnimeSource.animesOrion,
        AnimeSource.animesHd,
      ]) {
        expect(s.isPtBr, isTrue, reason: '$s deve contar como fonte PT-BR');
      }
      // Novas fontes entram entre o cluster AnimesOnline (9) e o AnimePlayer.
      expect(AnimeSource.animesOnlineHdk.priority,
          greaterThan(AnimeSource.animePlay.priority));
      expect(AnimeSource.animesHd.priority, lessThan(AnimeSource.animePlayer.priority));
    });

    test('all new sources participate in the aggregated search fan-out', () {
      final sources = SourceRegistry.adapters
          .where((a) => a.implemented)
          .map((a) => a.source)
          .toSet();
      expect(sources, containsAll([
        AnimeSource.animesOnlineHdk,
        AnimeSource.animesOrion,
        AnimeSource.animesHd,
      ]));
    });
  });
}