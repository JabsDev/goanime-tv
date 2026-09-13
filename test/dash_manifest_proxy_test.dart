import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/features/player/dash_manifest_proxy.dart';

/// Fixture mínima fiel ao MPD real do akumast (1 Period, set de vídeo com
/// SegmentTemplate relativo + 3 Representations, set de áudio sem height).
const _mpd = '''<?xml version="1.0"?>
<MPD type="static" mediaPresentationDuration="PT1420.003S" minBufferTime="PT6S">
  <Period>
    <AdaptationSet id="1" contentType="video">
      <SegmentTemplate timescale="1000" duration="6000" startNumber="1" media="/i/TOKEN/\$RepresentationID\$/\$Number\$.jpg" initialization="/i/TOKEN/\$RepresentationID\$/i.jpg">
      </SegmentTemplate>
      <Representation id="R480" mimeType="video/mp4" width="854" height="480" bandwidth="2111798">
      </Representation>
      <Representation id="R720" mimeType="video/mp4" width="1280" height="720" bandwidth="3628622">
      </Representation>
      <Representation id="R1080" mimeType="video/mp4" width="1920" height="1080" bandwidth="8718454">
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="2" contentType="audio" lang="pt">
      <SegmentTemplate timescale="1000" duration="6000" media="/i/TOKEN/A/\$Number\$.jpg" initialization="/i/TOKEN/A/i.jpg">
      </SegmentTemplate>
      <Representation id="A" mimeType="audio/mp4" bandwidth="130014">
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

final _base = Uri.parse('https://akumast.net/i/TOKEN/m.jpg');

void main() {
  test('absolutiza SegmentTemplate relativo, sem filtrar (height null)',
      () {
    final out =
        DashManifestProxy.rewriteManifest(mpd: _mpd, base: _base, height: null);
    expect(out, contains('media="https://akumast.net/i/TOKEN/\$RepresentationID\$'));
    expect(out, contains('initialization="https://akumast.net/i/TOKEN/A/i.jpg"'));
    expect(out, contains('id="R480"'));
    expect(out, contains('id="R720"'));
    expect(out, contains('id="R1080"'));
    expect(out, contains('id="A"'));
  });

  test('height=720 mantém só R720 + áudio', () {
    final out =
        DashManifestProxy.rewriteManifest(mpd: _mpd, base: _base, height: 720);
    expect(out, isNot(contains('id="R480"')));
    expect(out, contains('id="R720"'));
    expect(out, isNot(contains('id="R1080"')));
    // Áudio nunca é tocado.
    expect(out, contains('id="A"'));
    expect(out, contains('https://akumast.net/i/TOKEN/A/'));
  });

  test('height sem match serve o manifesto cheio (graceful)', () {
    final out =
        DashManifestProxy.rewriteManifest(mpd: _mpd, base: _base, height: 2160);
    expect(out, contains('id="R480"'));
    expect(out, contains('id="R1080"'));
  });

  test('serveManifest expõe .mpd em loopback com content-type dash+xml',
      () async {
    final proxy = DashManifestProxy(
      client: MockClient((req) async {
        expect(req.url.host, 'akumast.net');
        expect(req.headers['Referer'], contains('animefire.io'));
        return http.Response(_mpd, 200);
      }),
    );
    try {
      final uri = await proxy.serveManifest(
        manifestUrl: 'https://akumast.net/i/TOKEN/m.jpg',
        height: 480,
        headers: const {'Referer': 'https://animefire.io/'},
      );
      expect(uri.host, '127.0.0.1');
      expect(uri.path.endsWith('.mpd'), isTrue);

      final got = await http.get(uri);
      expect(got.statusCode, 200);
      expect(got.headers['content-type'], contains('application/dash+xml'));
      // Demuxer DASH relê o manifesto e falha sobre chunked sem tamanho:
      // Content-Length precisa existir e bater com os bytes (UTF-8!).
      expect(got.headers['content-length'], isNotNull);
      expect(got.bodyBytes.length, int.parse(got.headers['content-length']!));
      expect(got.body, contains('id="R480"'));
      expect(got.body, isNot(contains('id="R720"')));
      expect(got.body, contains('id="A"'));

      final missing = await http.get(
          Uri.parse('http://127.0.0.1:${uri.port}/nope.mpd'));
      expect(missing.statusCode, 404);
    } finally {
      await proxy.close();
    }
  });

  group('videoCodecs (tela preta AV1 no projetor)', () {
    const av1Mpd = '''<?xml version="1.0"?>
<MPD type="static">
  <Period>
    <AdaptationSet id="1" contentType="video">
      <Representation id="V480" mimeType="video/mp4" codecs="av01.0.04M.08" width="854" height="480" bandwidth="850003">
      </Representation>
      <Representation id="V1080" mimeType="video/mp4" codecs="av01.0.08M.08" width="1920" height="1080" bandwidth="3431186">
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="2" contentType="audio">
      <Representation id="A" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="131785">
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

    test('manifesto AV1-only (S4E21 real) → codecs av01, sem o áudio', () {
      final codecs = DashManifestProxy.videoCodecs(body: av1Mpd);
      expect(codecs, {'av01.0.04M.08', 'av01.0.08M.08'});
      expect(DashManifestProxy.isAv1Only(codecs), isTrue);
    });

    test('H.264 não é AV1-only', () {
      const avcMpd = '''<MPD><Period>
<AdaptationSet contentType="video">
<Representation mimeType="video/mp4" codecs="avc1.64001f" width="1280" height="720"></Representation>
</AdaptationSet></Period></MPD>''';
      final codecs = DashManifestProxy.videoCodecs(body: avcMpd);
      expect(codecs, {'avc1.64001f'});
      expect(DashManifestProxy.isAv1Only(codecs), isFalse);
    });

    test('sem codecs declarados → vazio (fail-open, tenta tocar)', () {
      final codecs = DashManifestProxy.videoCodecs(body: _mpd);
      expect(codecs, isEmpty);
      expect(DashManifestProxy.isAv1Only(codecs), isFalse);
    });

    test('serveManifest preenche lastVideoCodecs', () async {
      final proxy = DashManifestProxy(
        client: MockClient((_) async => http.Response(av1Mpd, 200)),
      );
      try {
        await proxy.serveManifest(manifestUrl: 'https://akumast.net/i/X/m.jpg');
        expect(proxy.lastVideoCodecs, contains('av01.0.08M.08'));
      } finally {
        await proxy.close();
      }
    });
  });

  test('fetch 404 propaga para o chamador cair no fallback direto', () async {
    final proxy = DashManifestProxy(
      client: MockClient((_) async => http.Response('nope', 404)),
    );
    try {
      await expectLater(
        proxy.serveManifest(manifestUrl: 'https://akumast.net/i/X/m.jpg'),
        throwsA(isA<HttpException>()),
      );
    } finally {
      await proxy.close();
    }
  });

  group('HLS (Slime S4E21 real: /h.jpg devolve #EXTM3U, não MPD)', () {
    // Multivariant fiel ao akumast: 3 variantes AV1 + áudio muxado, URIs
    // relativas (resolvem contra o manifesto do CDN, não contra 127.0.0.1).
    const hls = '''#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=981788,RESOLUTION=854x480,CODECS="av01.0.04M.08,mp4a.40.2"
oIHfuRJd74E/p.jpg
#EXT-X-STREAM-INF:BANDWIDTH=1914092,RESOLUTION=1280x720,CODECS="av01.0.05M.08,mp4a.40.2"
oILfuRJd74E/p.jpg
#EXT-X-STREAM-INF:BANDWIDTH=3562971,RESOLUTION=1920x1080,CODECS="av01.0.08M.08,mp4a.40.2"
oIPfuRJd74E/p.jpg
''';
    final hBase = Uri.parse('https://akumast.net/i/TOKEN/h.jpg');

    test('isHls distingue #EXTM3U de MPD', () {
      expect(DashManifestProxy.isHls(body: hls), isTrue);
      expect(DashManifestProxy.isHls(body: _mpd), isFalse);
    });

    test('CODECS av01+mp4a → só vídeo, AV1-only', () {
      final codecs = DashManifestProxy.videoCodecs(body: hls);
      expect(codecs,
          {'av01.0.04M.08', 'av01.0.05M.08', 'av01.0.08M.08'});
      expect(DashManifestProxy.isAv1Only(codecs), isTrue);
    });

    test('HLS H.264 não é AV1-only', () {
      const avc = '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1280x720,'
          'CODECS="avc1.64001f,mp4a.40.2"\nseg/p.jpg\n';
      final codecs = DashManifestProxy.videoCodecs(body: avc);
      expect(codecs, {'avc1.64001f'});
      expect(DashManifestProxy.isAv1Only(codecs), isFalse);
    });

    test('height=720 absolutiza e mantém só a variante 720', () {
      final out = DashManifestProxy.rewriteHls(
          playlist: hls, base: hBase, height: 720);
      expect(out, contains('RESOLUTION=1280x720'));
      expect(out, isNot(contains('RESOLUTION=854x480')));
      expect(out, isNot(contains('RESOLUTION=1920x1080')));
      // URI relativa vira CDN absoluta (nunca 127.0.0.1).
      expect(out,
          contains('https://akumast.net/i/TOKEN/oILfuRJd74E/p.jpg'));
      expect(out, isNot(contains('127.0.0.1')));
    });

    test('height sem match serve a playlist cheia', () {
      final out = DashManifestProxy.rewriteHls(
          playlist: hls, base: hBase, height: 2160);
      expect(out, contains('RESOLUTION=854x480'));
      expect(out, contains('RESOLUTION=1920x1080'));
    });

    test('serveManifest expõe .m3u8 com content-type HLS', () async {
      final proxy = DashManifestProxy(
        client: MockClient((_) async => http.Response(hls, 200)),
      );
      try {
        final uri = await proxy.serveManifest(
          manifestUrl: 'https://akumast.net/i/TOKEN/h.jpg',
          height: 1080,
        );
        expect(uri.path.endsWith('.m3u8'), isTrue);
        expect(proxy.lastIsHls, isTrue);
        expect(proxy.lastVideoCodecs, contains('av01.0.08M.08'));
        final got = await http.get(uri);
        expect(got.statusCode, 200);
        expect(got.headers['content-type'], contains('mpegURL'));
        expect(got.body, contains('RESOLUTION=1920x1080'));
        expect(got.body, isNot(contains('RESOLUTION=854x480')));
        // Full-chain: variantes apontam para o loopback, nunca para o CDN
        // (o HTTP do player não passa no CDN do aparelho sem decoder).
        expect(got.body, contains('/af-0v0.m3u8'));
        expect(got.body, isNot(contains('akumast.net')));
      } finally {
        await proxy.close();
      }
    });

    test('full-chain: variante e segmento servidos via loopback', () async {
      const variant = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
          '#EXT-X-MAP:URI="i.jpg"\n#EXTINF:6.000,\n1.jpg\n';
      final proxy = DashManifestProxy(
        client: MockClient((req) async {
          final p = req.url.path;
          if (p.endsWith('/h.jpg')) return http.Response(hls, 200);
          // Segmentos antes da variante: moram no mesmo diretório dela.
          if (p.endsWith('/1.jpg') || p.endsWith('/i.jpg')) {
            return http.Response.bytes([1, 2, 3, 4], 200,
                headers: {'content-type': 'video/mp4'});
          }
          if (p.contains('oIPfuRJd74E')) return http.Response(variant, 200);
          return http.Response('nope', 404);
        }),
      );
      try {
        final master = await proxy.serveManifest(
          manifestUrl: 'https://akumast.net/i/TOKEN/h.jpg',
          height: 1080,
        );
        final masterBody = (await http.get(master)).body;
        final variantPath = RegExp(r'(/[^\s"]+\.m3u8)').firstMatch(masterBody);
        expect(variantPath, isNotNull);
        final sub = await http.get(
            Uri.parse('http://127.0.0.1:${master.port}${variantPath!.group(1)}'));
        expect(sub.statusCode, 200);
        // Segmentos e MAP também viram loopback (relativos ao CDN, não
        // contra 127.0.0.1).
        expect(sub.body, contains(RegExp(r'/af-0-s\d+\.m4s')));
        expect(sub.body, isNot(contains('akumast.net')));
        final segPath =
            RegExp(r'(/[^\s"]+-s\d+\.m4s)').firstMatch(sub.body)!.group(1)!;
        final seg = await http.get(
            Uri.parse('http://127.0.0.1:${master.port}$segPath'));
        expect(seg.statusCode, 200);
        expect(seg.bodyBytes, [1, 2, 3, 4]);
      } finally {
        await proxy.close();
      }
    });
  });
}
