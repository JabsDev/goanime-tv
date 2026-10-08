import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/sources/animesdigital_adapter.dart';
import 'package:goanime_tv/core/sources/anime_fire_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/data/models/episode.dart';

/// Mock client com rota por substring + contagem de chamadas. Os headers de
/// referer/cookie são inspecionáveis no Request.
typedef Route = http.Response Function(http.Request req);

MockClient routedMock(Map<String, Route> routes) {
  return MockClient((req) async {
    for (final pattern in routes.keys) {
      if (req.url.toString().contains(pattern)) return routes[pattern]!(req);
    }
    return http.Response('unrouted ${req.url}', 404);
  });
}

const animeSearchHtml = '''
<div class="itemA"><a href="https://animesdigital.org/anime/a/kimi-ga-shinu-made-koi-wo-shitai-todos-episodios" title="Assistir Kimi ga Shinu made Koi wo Shitai Online em HD"><div class="title"><span class="title_anime">Kimi ga Shinu made Koi wo Shitai</span></div></a></div>''';

const kimiAnimePage = '''
<div class="lista_episodes"><div class="itens_ep">
<div class="item_ep b_flex"><a href="https://animesdigital.org/video/a/139033/" class="b_flex"><div class="dados"><div class="title_anime">Kimi ga Shinu made Koi wo Shitai Episódio 13</div></div></a></div>
<div class="item_ep b_flex"><a href="https://animesdigital.org/video/a/136987/" class="b_flex"><div class="dados"><div class="title_anime">Kimi ga Shinu made Koi wo Shitai Episódio 01</div></div></a></div>
</div></div>''';

/// EP1: player1 → investcentro(meta refresh) → mixumenu(302+cookie) → artigo →
/// videohls.php(Referer exigido) → STCode com file:'…m3u8' → HLS vivo.
const kimiEp1Page = '''
<div id="player1" class="tab-video" data-id="136987" data-video="1">
<a class="ad-protected-cover" href="https://investcentro.com/campaign.php?token=tok1&amp;x=1"></a>
</div>
<div id="player2" class="tab-video" data-id="136987" data-video="2">
<a class="ad-protected-cover" href="https://investcentro.com/campaign.php?token=tok2&amp;x=2"></a>
</div>''';

const mixuArticleFhd = '''
<div id="media-display" data-url="https://api.anivideo.net/videohls.php?d=https://cdn-s01.stream/kimi/01.mp4/index.m3u8&amp;nocache=123"></div>''';

const stCodeWithHls = '''
<script>var p = jwplayer('video-player').setup({playlist:[{sources:[{label:"720p HD", file:'https://cdn-s01.stream/kimi/01.mp4/index.m3u8'}]}]});</script>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Anime anime() => Anime(
        name: 'Kimi ga Shinu made Koi wo Shitai',
        englishName: 'I Want to Love You Till Your Dying Day',
        url: '',
        source: AnimeSource.animesDigital,
        anilistId: 187260,
        episodes: 13,
      );

  test('fluxo completo: search → episodes → resolveVideo (player1 FHD)',
      () async {
    final calls = <String>[];
    final client = routedMock({
      'pesquisa/': (_) {
        calls.add('search');
        return http.Response(animeSearchHtml, 200);
      },
      'anime/a/kimi-ga-shinu': (_) {
        calls.add('episodes');
        return http.Response(kimiAnimePage, 200);
      },
      '/video/a/136987/': (_) {
        calls.add('videoPage');
        return http.Response(kimiEp1Page, 200);
      },
      'investcentro.com': (req) {
        calls.add('investcentro');
        expect(req.headers['user-agent'], contains('Android TV'));
        // 302 → mixumenu (set-cookie no header do http package vira 'location')
        return http.Response(
            '', 302,
            headers: {
              'location':
                  'https://mixumenu.com/campaign.php?token=tok1&x=1',
              'set-cookie': 'token=tok1; path=/; Max-Age=300, '
                  'post_data=x%7By%7D; path=/',
            });
      },
      'mixumenu.com': (req) {
        calls.add('mixumenu');
        return http.Response(mixuArticleFhd, 200);
      },
      'videohls.php': (req) {
        calls.add('videohls');
        expect(req.headers['referer'], contains('animesdigital.org'));
        return http.Response(stCodeWithHls, 200);
      },
      'index.m3u8': (_) {
        calls.add('m3u8probe');
        return http.Response('#EXTM3U\n#EXT-X-VERSION:3\n(click)', 200);
      },
    });

    final adapter = AnimesDigitalAdapter(client: client);
    final result = await adapter.resolveVideo(anime(), 1, catalog: anime());
    expect(result, hasLength(1));
    expect(result.single.url, 'https://cdn-s01.stream/kimi/01.mp4/index.m3u8');
    expect(result.single.quality, 'HD');
    expect(result.single.dashHeight, isNull);
    // O fluxo inteiro passou pela cadeia, incluindo o probe do manifest:
    expect(calls, contains('m3u8probe'));
  });

  test('EP não listado → resolveVideo vazio (sem exception)', () async {
    final client = routedMock({
      'pesquisa/': (_) => http.Response(animeSearchHtml, 200),
      'anime/a/kimi-ga-shinu': (_) => http.Response(kimiAnimePage, 200),
      '/video/a/136987/': (_) => http.Response('<div class="itens_ep">x</div>', 200),
    });
    final adapter = AnimesDigitalAdapter(client: client);
    final r = await adapter.resolveVideo(anime(), 99, catalog: anime());
    expect(r, isEmpty);
  });

  test('player1 com campanha falha → fallback para player2', () async {
    final client = routedMock({
      'pesquisa/': (_) => http.Response(animeSearchHtml, 200),
      'anime/a/kimi-ga-shinu': (_) => http.Response(kimiAnimePage, 200),
      '/video/a/136987/': (_) => http.Response(kimiEp1Page, 200),
      // Sem player1 do lado do investcentro (500)…
      'investcentro.com/campaign.php?token=tok1':
          (_) => http.Response('gone', 404),
      'investcentro.com': (req) {
        // …, o player2 token cai aqui e funciona.
        return http.Response(
            '', 302,
            headers: {'location': 'https://mixumenu.com/campaign.php?x=2'});
      },
      'mixumenu.com': (_) => http.Response(mixuArticleFhd, 200),
      'videohls.php': (_) => http.Response(stCodeWithHls, 200),
      'index.m3u8': (_) => http.Response('#EXTM3U\nx', 200),
    });

    final adapter = AnimesDigitalAdapter(client: client);
    final r = await adapter.resolveVideo(anime(), 1, catalog: anime());
    expect(r, hasLength(1)); // veio do player2
  });

  test('CookieJar: parse de header set-cookie com múltiplos cookies', () {
    final jar = CookieJar();
    jar.collect(http.Response('', 200, headers: {
      'set-cookie':
          'token=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0; '
              'path=/, token=TOKEN_OK; path=/; Max-Age=300, '
              'post_data=%7Bx%3D1%7D; path=/',
    }));
    expect(jar.jar.keys, containsAll(['token', 'post_data']));
    expect(jar.jar['token'], 'TOKEN_OK');
    expect(jar.jar['post_data'], '%7Bx%3D1%7D');
    final h = jar.headerFor(Uri.parse('https://mixumenu.com/x'));
    expect(h!['Cookie']!.startsWith('token=TOKEN_OK'), isTrue);
  });

  test('CookieJar.headerFor de_COLLECTION quando jar vazio null', () {
    final jar = CookieJar();
    expect(jar.headerFor(Uri.parse('https://x.com/')), isNull);
  });

  test('animeFire: stream 404 no CDN é descartado (probe de manifest)',
      () async {
    final streamsJson = '''
{"data":{"streams":[
 {"audio":"legendado","is_offline":false,
  "url":"https://akumast.net/i/DEAD/h.jpg","qualities":["480p","720p"]},
 {"audio":"dublado","is_offline":false,
  "url":"https://akumast.net/i/LIVE/h.jpg","qualities":["480p"]}
]}}''';
    final client = routedMock({
      'api.animefire.one/episode/epx':
          (_) => http.Response(streamsJson, 200),
      'akumast.net/i/DEAD/h.jpg': (_) => http.Response('gone', 404),
      'akumast.net/i/LIVE/h.jpg': (_) =>
          http.Response('<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">x', 200),
    });

    final adapter = AnimeFireAdapter(client: client);
    final episode = Episode(
        number: '8',
        url: 'https://api.animefire.one/episode/epx',
        owner: Anime(name: 'X', url: 'https://animefire.one/anime/abc'));
    final r = await adapter.getVideoSources(episode);
    expect(r, isA<Success<List<VideoSource>>>());
    final data = (r as Success<List<VideoSource>>).data;
    expect(data, hasLength(1));
    expect(data.single.url, contains('LIVE'));
  });

  test('animeFire: TODO stream morto → EmptyResultError (matchedUnavailable)',
      () async {
    final streamsJson = '''
{"data":{"streams":[
 {"audio":"legendado","is_offline":false,
  "url":"https://akumast.net/i/DEAD/h.jpg","qualities":["480p"]}
]}}''';
    final client = routedMock({
      'episode/epx': (_) => http.Response(streamsJson, 200),
      'akumast.net': (_) => http.Response('', 404),
    });
    final adapter = AnimeFireAdapter(client: client);
    final episode = Episode(
        number: '8',
        url: 'https://api.animefire.one/episode/epx',
        owner: Anime(name: 'X', url: 'https://animefire.one/anime/abc'));
    final r = await adapter.getVideoSources(episode);
    expect(r, isA<Failure<List<VideoSource>>>());
    final err = (r as Failure<List<VideoSource>>).error;
    expect(err.message, contains('dead (CDN 404)'));
  });
}
