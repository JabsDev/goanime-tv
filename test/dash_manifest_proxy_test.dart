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
      final codecs = DashManifestProxy.videoCodecs(mpd: av1Mpd);
      expect(codecs, {'av01.0.04M.08', 'av01.0.08M.08'});
      expect(DashManifestProxy.isAv1Only(codecs), isTrue);
    });

    test('H.264 não é AV1-only', () {
      const avcMpd = '''<MPD><Period>
<AdaptationSet contentType="video">
<Representation mimeType="video/mp4" codecs="avc1.64001f" width="1280" height="720"></Representation>
</AdaptationSet></Period></MPD>''';
      final codecs = DashManifestProxy.videoCodecs(mpd: avcMpd);
      expect(codecs, {'avc1.64001f'});
      expect(DashManifestProxy.isAv1Only(codecs), isFalse);
    });

    test('sem codecs declarados → vazio (fail-open, tenta tocar)', () {
      final codecs = DashManifestProxy.videoCodecs(mpd: _mpd);
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
}
