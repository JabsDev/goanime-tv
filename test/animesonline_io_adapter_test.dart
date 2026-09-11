import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/sources/animesonline_io_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';

// Fixtures no formato real do site (reduzidas).
const _search = '''
<html><body>
<article class="bs"><div class="bsx">
<a href="https://animesonline.io/anime/naruto-shippuden/" title="Naruto Shippuden">
<img data-src="https://animesonline.io/wp-content/uploads/n.jpg" />
<div class="tt">Naruto Shippuden</div></a>
</div></article>
</body></html>
''';

const _anime = '''
<html><body><ul>
<li><a href="https://animesonline.io/15861/"><div class="epl-num">003</div></a></li>
<li><a href="https://animesonline.io/15859/"><div class="epl-num">001</div></a></li>
<li><a href="https://animesonline.io/15860/"><div class="epl-num">002</div></a></li>
<li><a href="https://animesonline.io/anime/x/page/2">2</a></li>
<li><a href="https://animesonline.io/54365/">post sem epl-num (widget)</a></li>
</ul></body></html>
''';

// value="(base64 de <iframe src="https://anidrive.click/token/ABC">)"
const _episode =
    '<html><body><input value="PGlmcmFtZSBzcmM9Imh0dHBzOi8vYW5pZHJpdmUuY2xpY2svdG9rZW4vQUJDIj48L2lmcmFtZT4=" /></body></html>';

// Bootstrap ofuscado (array + permutação + XOR) cujo payload contém o file.
// Gerado por script: plaintext
// `window.Cfg={"sources":[{"file":"https://cdn.example.com/v.mp4"}]}`.
const _token = '''
<html><body><script type="text/javascript">
(function(){function _a(_b,_c,_d){}}(0,Function)();}_f(["sh2IEDPKv/VQSZn65vTG8R","DivTlk5x3scRBc2I6T4ZOA","NsmCUjzfqxQGnt2uNRcgCS","7Y3EJpnasBTJ2D/28LEAQ="],[1,0,2,3],"eUK98iEG8IR3YvDzy012TQ==");})();
</script></body></html>
''';

http.Response _ok(String body) =>
    http.Response(body, 200, headers: {'content-type': 'text/html'});

void main() {
  test('search extrai cards article.bs', () async {
    final adapter = AnimesOnlineIoAdapter(
      client: MockClient((req) async {
        expect(req.url.queryParameters['s'], 'naruto');
        return _ok(_search);
      }),
    );
    final res = await adapter.search('naruto');
    expect(res, isA<Success<List<Anime>>>());
    final data = (res as Success<List<Anime>>).data;
    expect(data.single.name, 'Naruto Shippuden');
    expect(data.single.url, 'https://animesonline.io/anime/naruto-shippuden/');
  });

  test('getEpisodes ordena pelo epl-num e ignora paginação', () async {
    final adapter = AnimesOnlineIoAdapter(
      client: MockClient((_) async => _ok(_anime)),
    );
    final res = await adapter.getEpisodes(Anime(
      name: 'X',
      url: 'https://animesonline.io/anime/x/',
      source: AnimeSource.animesOnlineIo,
    ));
    expect(res, isA<Success<List<Episode>>>());
    final eps = (res as Success<List<Episode>>).data;
    expect(eps.map((e) => e.number).toList(), ['1', '2', '3']);
    expect(eps.first.url, 'https://animesonline.io/15859/');
  });

  test('tokenUrl decodifica o iframe base64', () {
    expect(
      AnimesOnlineIoAdapter.tokenUrl(_episode),
      'https://anidrive.click/token/ABC',
    );
  });

  test('cookies repassa name=value do set-cookie', () {
    expect(
      AnimesOnlineIoAdapter.cookies({
        'set-cookie': 'a=1; Path=/, b=2; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/'
      }),
      'a=1; b=2',
    );
    expect(AnimesOnlineIoAdapter.cookies({}), isEmpty);
  });

  test('playerFile desemaranha array+permutação+XOR', () {
    expect(
      AnimesOnlineIoAdapter.playerFile(_token),
      'https://cdn.example.com/v.mp4',
    );
    expect(AnimesOnlineIoAdapter.playerFile('<html></html>'), isNull);
  });

  test('getVideoSources fim-a-fim com mocks (probe 206)', () async {
    final adapter = AnimesOnlineIoAdapter(
      client: MockClient((req) async {
        final u = req.url.toString();
        if (u == 'https://animesonline.io/15859/') {
          return http.Response(_episode, 200, headers: {
            'content-type': 'text/html',
            'set-cookie': 'a=1; Path=/',
          });
        }
        if (u == 'https://anidrive.click/token/ABC') {
          expect(req.headers['cookie'], contains('a=1'));
          expect(req.headers['Referer'], 'https://animesonline.io/15859/');
          return _ok(_token);
        }
        if (u == 'https://cdn.example.com/v.mp4') {
          return http.Response('x', 206, headers: {
            'content-range': 'bytes 0-0/100',
          });
        }
        return http.Response('nf', 404);
      }),
    );
    final res = await adapter.getVideoSources(
      Episode(number: '1', url: 'https://animesonline.io/15859/'),
    );
    expect(res, isA<Success<List<VideoSource>>>());
    final data = (res as Success<List<VideoSource>>).data;
    expect(data.single.url, 'https://cdn.example.com/v.mp4');
  });
}
