// Self-checks for [BloggerSpaResolver]: the deterministic walk that turns a
// Blogger embed (direct `video.g?token=` or the DooPlay `jwplayer/?source=`
// base64 wrapper) into a playable stream, plus the BloggerUnsupportedError
// classification in [DooPlayAdapter].
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/blogger_spa_resolver.dart';
import 'package:goanime_tv/core/sources/dooplay_adapter.dart';

http.Response _ok(String body, {int status = 200}) =>
    http.Response(body, status, headers: {'content-type': 'text/html'});

http.Response _json(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

http.Response _probe() => http.Response(
      'x',
      206,
      headers: {'content-range': 'bytes 0-0/125505938'},
    );

/// Builds the DooPlay `jwplayer/?source=` wrapper: `source` is the base64 of
/// the REVERSED blogger `video.g` URL (how the sites obfuscate the token).
String _jwrapper(String token) {
  final bloggerUrl = 'https://www.blogger.com/video.g?token=$token';
  final reversed = bloggerUrl.split('').reversed.join();
  final b64 = base64Encode(utf8.encode(reversed));
  return 'https://betteranime.io/jwplayer/?source=$b64&id=10406&type=blogger';
}

void main() {
  const token = 'AD6v5TESTTOKEN123';

  test('direct mp4 already in the embed is offered after a 206 probe', () async {
    const direct = 'https://cdn.example.com/Animes/Letra-N/Naruto/01.mp4';
    final resolver = BloggerSpaResolver(
      client: MockClient((req) async {
        if (req.url.path.endsWith('.mp4')) return _probe();
        return http.Response('nf', 404);
      }),
    );
    final sources = await resolver.resolve(
      embedUrl:
          'https://betteranime.io/jwplayer?source=${Uri.encodeComponent(direct)}&id=1&type=mp4',
      referer: 'https://betteranime.io/',
    );
    expect(sources, hasLength(1));
    expect(sources.first.url, direct);
    expect(sources.first.headers['Referer'], 'https://betteranime.io/');
  });

  test('video-play.mp4?contentID answers 206 → direct stream from token',
      () async {
    final resolver = BloggerSpaResolver(
      client: MockClient((req) async {
        if (req.url.host == 'www.blogger.com' &&
            req.url.path == '/video-play.mp4' &&
            req.url.queryParameters['contentID'] == token) {
          return _probe();
        }
        return http.Response('nf', 404);
      }),
    );
    final sources = await resolver.resolve(
      embedUrl: _jwrapper(token),
      referer: 'https://betteranime.io/',
    );
    expect(sources, hasLength(1));
    expect(sources.first.url,
        'https://www.blogger.com/video-play.mp4?contentID=$token');
  });

  test('SPA page with an escaped media URL → stream recovered', () async {
    // Blogger SPA serves JSON-escaped strings: `\u0026` = `&`.
    const mediaUrl = 'https://video-downloads.googleusercontent.com/v/720.mp4';
    final resolver = BloggerSpaResolver(
      client: MockClient((req) async {
        if (req.url.host == 'www.blogger.com' &&
            req.url.path == '/video.g') {
          return _ok(
              '<html><body><div id="vid" data-url="\\"$mediaUrl?x=1\\u0026y=2\\""></div></body></html>');
        }
        if (req.url.path == '/video-play.mp4') {
          return http.Response('nf', 404);
        }
        if (req.url.path.endsWith('/720.mp4')) return _probe();
        return http.Response('nf', 404);
      }),
    );
    final sources = await resolver.resolve(
      embedUrl: 'https://www.blogger.com/video.g?token=$token',
      referer: 'https://betteranime.io/',
    );
    expect(sources, hasLength(1));
    expect(sources.first.url, '$mediaUrl?x=1&y=2');
  });

  test('dead token → empty list (caller classifies as BloggerUnsupported)',
      () async {
    final resolver = BloggerSpaResolver(
      client: MockClient((req) async {
        // video-play/redirector 404, SPA page has no recoverable media URL.
        if (req.url.host == 'www.blogger.com' && req.url.path == '/video.g') {
          return _ok('<html><body><div id="video">SPA</div></body></html>');
        }
        return http.Response('nf', 404);
      }),
    );
    final sources = await resolver.resolve(
      embedUrl: 'https://www.blogger.com/video.g?token=$token',
      referer: 'https://betteranime.io/',
    );
    expect(sources, isEmpty);
  });

  test('DooPlayAdapter classifies a blogger embed as BloggerUnsupportedError',
      () async {
    final adapter = DooPlayAdapter(
      source: AnimeSource.dooPlay,
      client: MockClient((req) async {
        if (req.url.path == '/episodios/naruto-shippuden-episodio-1/') {
          return _ok(
              "<html><body><div id='player-option-1' class='dooplay_player_option' data-type='tv' data-post='10406' data-nume='1'></div></body></html>");
        }
        if (req.url.path.startsWith('/wp-json/dooplayer/v2/')) {
          return _json(
              '{"embed_url":"https://www.blogger.com/video.g?token=$token","type":"iframe"}');
        }
        if (req.url.host == 'www.blogger.com') {
          return _ok('<html><body><div id="video">SPA</div></body></html>');
        }
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '1', url: 'https://betteranime.io/episodios/naruto-shippuden-episodio-1/'),
    );
    expect(result, isA<Failure<List<VideoSource>>>());
    expect(((result as Failure).error), isA<BloggerUnsupportedError>());
  });

  test('non-blogger empty embed keeps the plain EmptyResultError', () async {
    final adapter = DooPlayAdapter(
      source: AnimeSource.dooPlay,
      client: MockClient((req) async {
        if (req.url.path == '/episodios/x-episodio-1/') {
          return _ok(
              "<html><body><div id='player-option-1' class='dooplay_player_option' data-type='tv' data-post='1' data-nume='1'></div></body></html>");
        }
        if (req.url.path.startsWith('/wp-json/dooplayer/v2/')) {
          return _json('{"embed_url":"https://player.example/embed/xyz","type":"iframe"}');
        }
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '1', url: 'https://betteranime.io/episodios/x-episodio-1/'),
    );
    expect(result, isA<Failure<List<VideoSource>>>());
    final failure = result as Failure<List<VideoSource>>;
    expect(failure.error, isA<EmptyResultError>());
    expect(failure.error, isNot(isA<BloggerUnsupportedError>()));
  });
}