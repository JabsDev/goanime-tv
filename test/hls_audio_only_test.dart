import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/hls_audio_only.dart';

const _master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Stereo",DEFAULT=YES,URI="aud.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="en.vtt"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aud"
index-720p.m3u8
''';

const _audioPl = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6.0,
seg1.m4s
#EXTINF:6.0,
seg2.m4s
#EXT-X-ENDLIST
''';

void main() {
  group('HlsAudioOnly', () {
    test('resolve playlist de áudio do master', () async {
      final uri = await HlsAudioOnly.audioPlaylistUri('https://x/hls/m.m3u8',
          fetchForTest: (_) async => _master);
      expect(uri.toString(), 'https://x/hls/aud.m3u8');
    });

    test('null sem grupo AUDIO ou sem m3u8', () async {
      expect(
          await HlsAudioOnly.audioPlaylistUri('https://x/v.mp4',
              fetchForTest: (_) async => _master),
          isNull);
      expect(
          await HlsAudioOnly.audioPlaylistUri('https://x/m.m3u8',
              fetchForTest: (_) async => '#EXTM3U'),
          isNull);
    });

    test('concatena init + segmentos em ordem', () async {
      final tmp = await Directory.systemTemp.createTemp('hlsaud');
      try {
        final bodies = {
          'aud.m3u8': _audioPl,
        };
        final bytes = {
          'https://x/hls/init.mp4': [1, 2],
          'https://x/hls/seg1.m4s': [3],
          'https://x/hls/seg2.m4s': [4, 5],
        };
        var progressCalls = 0;
        final out = await HlsAudioOnly.fetch(
          Uri.parse('https://x/hls/aud.m3u8'),
          File('${tmp.path}/a.aac'),
          fetchForTest: (_) async => bodies['aud.m3u8']!,
          fetchBytesForTest: (u) async {
            progressCalls++;
            return bytes[u.toString()]!;
          },
          onProgress: (_) => progressCalls++,
        );
        expect(out, isNotNull);
        expect(await out!.readAsBytes(), [1, 2, 3, 4, 5]);
        expect(progressCalls, greaterThan(3));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('AES-128 e BYTERANGE caem p/ fallback (null)', () async {
      final tmp = await Directory.systemTemp.createTemp('hlsaud2');
      try {
        final enc = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\nseg1.ts\n';
        expect(
            await HlsAudioOnly.fetch(Uri.parse('https://x/a.m3u8'),
                File('${tmp.path}/a.ts'),
                fetchForTest: (_) async => enc),
            isNull);
        final br =
            '#EXTM3U\n#EXTINF:6.0,\n#EXT-X-BYTERANGE:100@0\nseg1.ts\n';
        expect(
            await HlsAudioOnly.fetch(Uri.parse('https://x/a.m3u8'),
                File('${tmp.path}/b.ts'),
                fetchForTest: (_) async => br),
            isNull);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
