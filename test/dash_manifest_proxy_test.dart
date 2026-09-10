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
