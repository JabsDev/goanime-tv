import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/hls_subtitle_probe.dart';
import 'package:goanime_tv/core/subtitles/srt_parser.dart';

const _master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Stereo",DEFAULT=YES,URI="aud.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="en.vtt"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Espanol",LANGUAGE="es",URI="subs/es.m3u8"
#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC",INSTREAM-ID="CC1"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,SUBTITLES="subs",AUDIO="aud"
index-720p.m3u8
''';

void main() {
  group('HlsSubtitleProbe', () {
    test('extrai grupos SUBTITLES com URI absoluta', () {
      final subs = HlsSubtitleProbe.parse(_master,
          baseUri: Uri.parse('https://cdn.x/hls/master.m3u8'));
      expect(subs, hasLength(2));
      expect(subs[0].uri, 'https://cdn.x/hls/en.vtt');
      expect(subs[0].lang, 'en');
      expect(subs[1].uri, 'https://cdn.x/hls/subs/es.m3u8');
    });

    test('ignora AUDIO e CLOSED-CAPTIONS', () {
      final subs = HlsSubtitleProbe.parse(
          '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="a.m3u8"',
          baseUri: Uri.parse('https://x/m.m3u8'));
      expect(subs, isEmpty);
    });

    test('detectLang casa com o probe', () {
      final subs = HlsSubtitleProbe.parse(_master,
          baseUri: Uri.parse('https://cdn.x/hls/master.m3u8'));
      expect(
          subs.map((s) =>
              SrtParser.detectLang(tag: '${s.label} ${s.lang}')),
          ['en', 'es']);
    });

    test('probe falha aberto (não-m3u8 e erro de rede)', () async {
      expect(await HlsSubtitleProbe.probe('https://x/v.mp4'), isEmpty);
      expect(
          await HlsSubtitleProbe.probe('https://x/m.m3u8',
              fetchForTest: (_) => throw const SocketException('down')),
          isEmpty);
    });

    test('probe usa fetch injetado', () async {
      final subs = await HlsSubtitleProbe.probe('https://x/m.m3u8',
          fetchForTest: (_) async => _master);
      expect(subs, hasLength(2));
    });
  });
}
