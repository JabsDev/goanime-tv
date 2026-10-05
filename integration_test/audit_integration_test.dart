import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/ai_providers.dart';
import 'package:goanime_tv/core/subtitles/model_manager.dart';
import 'package:goanime_tv/core/subtitles/srt_parser.dart';

/// Testa o CAMINHO INTEGRADO (não o provider direto): os arquivos ficam na
/// pasta de modelos do app (modelsDir/ja-seq2seq), Settings.auditKind aponta
/// para 'ja-seq2seq', e o job chamaria AiProviders.makeAudit() — aqui fazemos
/// exatamente isso e auditamos algumas cues.
///
/// Pré-requisito: encoder.onnx/decoder.onnx em /data/local/tmp/auditor/
/// (movidos p/ a pasta do app no início do teste).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  SrtCue c(int i, String t) => SrtCue(
      index: i, start: Duration.zero, end: const Duration(seconds: 1), text: t);

  testWidgets('auditor JA seq2seq integrado (makeAudit + catalogo)', (tester) async {
    final root = await const ModelManager().modelsDir();
    final dst = Directory('${root.path}/ja-seq2seq');
    await dst.create(recursive: true);
    for (final f in ['encoder.onnx', 'decoder.onnx']) {
      final d = File('${dst.path}/$f');
      if (await d.exists()) continue;
      final src = File('/data/local/tmp/auditor/$f');
      if (!await src.exists()) continue;
      try {
        await src.rename(d.path); // mesmo FS: instantâneo
      } catch (_) {
        // fallback em STREAM (readAsBytes de 220 MB estourava a RAM)
        await src.openRead().pipe(d.openWrite());
      }
    }
    final encOk = await File('${dst.path}/encoder.onnx').exists();
    final decOk = await File('${dst.path}/decoder.onnx').exists();
    // ignore: avoid_print
    print('modelsDir=${dst.path} enc=$encOk dec=$decOk');

    await SettingsService.instance.setAuditKind('ja-seq2seq');
    final a = await AiProviders.makeAudit();
    // ignore: avoid_print
    print('makeAudit -> ${a.runtimeType}');
    expect(a, isNotNull, reason: 'modelo nao instalado ou catalogo errado');
    await a!.load();

    final cues = [
      c(1, 'これこれ。'),
      c(2, 'んっ、んんっ!'),
      c(3, '私知恵私が知恵遅れだと言ったけど'),
      c(4, 'ジーンって街にあるんじゃないの?'),
    ];
    final sw = Stopwatch()..start();
    final out = await a.auditJa(cues);
    // ignore: avoid_print
    print('INTEGRADO_OK ${sw.elapsedMilliseconds}ms');
    for (var i = 0; i < out.length; i++) {
      // ignore: avoid_print
      print('  ${cues[i].text}  ->  ${out[i].text}');
    }
    await a.dispose();
    await SettingsService.instance.setAuditKind('off');
  });
}
