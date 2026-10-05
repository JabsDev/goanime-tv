import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:goanime_tv/core/subtitles/jav03_stt.dart';

/// Mede o RTF do whisper-small DESTILADO no APARELHO (edge 30), pelo motor
/// ORT. Substitui o teste do v0.3.
///   flutter test integration_test/jav03_stt_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('student destilado: transcrição + RTF', (tester) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/jav03-test');
    await dir.create(recursive: true);
    const src = '/data/local/tmp/jav03';
    // arquivos do student (formato optimum, mesmo motor do v0.3)
    for (final f in const [
      'mel.onnx',
      'encoder_model.int8.onnx',
      'encoder_model.int8.onnx.data',
      'decoder_model.int8.onnx',
      'decoder_model.int8.onnx.data',
      'tokens.txt',
    ]) {
      final dest = File('${dir.path}/$f');
      if (!await dest.exists()) {
        await Process.run('cp', ['$src/$f', dest.path]);
      }
    }
    final ch = MethodJav03Channel();
    final tok = await Jav03Tokenizer.load('${dir.path}/tokens.txt');
    // ids do modelo: [sot, <|ja|>, <|transcribe|>, <|notimestamps|>, <|eot|>]
    const prompt = [50258, 50266, 50359, 50363, 50257];
    const files = [
      'mel.onnx',
      'encoder_model.int8.onnx',
      'decoder_model.int8.onnx'
    ];

    var sw = Stopwatch()..start();
    // warm-up + carga (a 1a chamada inclui abrir as sessões)
    await ch.decode(
        dir.path, files, Float32List(1600), prompt);
    // ignore: avoid_print
    print('LOAD_MS=${sw.elapsedMilliseconds}');

    for (var i = 0; i < 3; i++) {
      final bytes = await File('$src/clip$i.pcm').readAsBytes();
      final shorts = bytes.buffer.asInt16List();
      final pcm = Float32List(shorts.length);
      for (var k = 0; k < shorts.length; k++) {
        pcm[k] = shorts[k] / 32768.0;
      }
      sw = Stopwatch()..start();
      final csv = await ch.decode(dir.path, files, pcm, prompt);
      sw.stop();
      final text = tok.detokenizeCsv(csv);
      final secs = pcm.length / 16000;
      // ignore: avoid_print
      print('CLIP$i audio=${secs.toStringAsFixed(2)}s '
          'decode=${sw.elapsedMilliseconds}ms '
          'rtf=${(sw.elapsedMilliseconds / 1000 / secs).toStringAsFixed(3)} '
          'hyp="$text"');
    }
    await ch.dispose();
  });
}
