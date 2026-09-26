import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/sherpa_stt.dart';

void main() {
  test('cópia cria vad.onnx na pasta do STT e retorna true', () async {
    final root = await Directory.systemTemp.createTemp('vad_root');
    final stt = Directory('${root.path}/whisper-tiny-ja');
    await stt.create(recursive: true);
    for (final f in [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'tokens.txt',
    ]) {
      await File('${stt.path}/$f').writeAsString('x');
    }
    await Directory('${root.path}/silero-vad').create();
    final src = File('${root.path}/silero-vad/vad.onnx');
    await src.writeAsBytes([1, 2, 3]);

    expect(await ensureVadInModelDir(stt.path, rootForTest: root), isTrue);
    expect(await File('${stt.path}/vad.onnx').readAsBytes(), [1, 2, 3]);
    // regressão 2.1: mesmo path que o SherpaSttEngine.init usa
    expect(await File('${stt.path}/vad.onnx').exists(), isTrue);
    await root.delete(recursive: true);
  });

  test('idempotente: 2ª chamada não re-copia nem corrompe', () async {
    final root = await Directory.systemTemp.createTemp('vad_root2');
    final stt = Directory('${root.path}/whisper-tiny-ja');
    await stt.create(recursive: true);
    await Directory('${root.path}/silero-vad').create();
    await File('${root.path}/silero-vad/vad.onnx').writeAsBytes([9]);
    final dest = File('${stt.path}/vad.onnx');

    expect(await ensureVadInModelDir(stt.path, rootForTest: root), isTrue);
    expect(await ensureVadInModelDir(stt.path, rootForTest: root), isTrue);
    expect(await dest.readAsBytes(), [9]);
    expect(await File('${stt.path}/vad.onnx.tmp').exists(), isFalse);
    await root.delete(recursive: true);
  });

  test('sem VAD na raiz: false, sem exceção, nada criado', () async {
    final root = await Directory.systemTemp.createTemp('vad_root3');
    final stt = Directory('${root.path}/whisper-tiny-ja');
    await stt.create(recursive: true);

    expect(await ensureVadInModelDir(stt.path, rootForTest: root), isFalse);
    expect(await File('${stt.path}/vad.onnx').exists(), isFalse);
    expect(await stt.list().toList(), hasLength(0));
    await root.delete(recursive: true);
  });
}
