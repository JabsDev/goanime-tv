import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/subtitle_job_manager.dart';

void main() {
  test('ReceivePort: 2 listens lançam mesmo com cancel (causa do 26%)',
      () async {
    final p = ReceivePort();
    final s = p.listen((_) {});
    await s.cancel();
    expect(() => p.listen((_) {}), throwsStateError);
    p.close();
  });

  test('friendlyError mapeia worker STT p/ PT-BR sem stack', () {
    expect(
        SubtitleJobManager.friendlyError(
            StateError('Bad state: Stream has already been listened to')),
        contains('Falha interna'));
    expect(
        SubtitleJobManager.friendlyError(
            StateError('worker STT sem resposta (timeout 10s). x')),
        contains('Voz'));
  });

  test('friendlyError mapeia dlopen nativo p/ PT-BR sem stack', () {
    final msg = SubtitleJobManager.friendlyError(PlatformException(
        code: 'LFM',
        message:
            'dlopen failed: cannot locate symbol "OrtGetApiBase" referenced by "/data/app/~~x/lib/arm64/libonnxruntime4j_jni.so"'));
    expect(msg, contains('Falha nas bibliotecas'));
    expect(msg.contains('dlopen'), isFalse);
  });
}
