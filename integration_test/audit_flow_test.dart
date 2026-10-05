import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/core/subtitles/auditor.dart';
import 'package:goanime_tv/core/subtitles/jav03_stt.dart';
import 'package:goanime_tv/core/subtitles/llm_mt.dart';
import 'package:goanime_tv/core/subtitles/srt_parser.dart';

/// FLUXO COMPLETO no aparelho, num anime real:
///   transcrever → auditar JA → traduzir → auditar PT → salvar os 2 SRTs
///
/// Os modelos (STT student, auditor GGUF, tradutor GGUF) e o PCM do EP3 vêm
/// por adb push (ver /tmp/opencode + /mnt/2TB/asr/ep3). O teste imprime os
/// SRTs no console e grava em /sdcard/Download p/ o dono ler o .srt.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const stg = '/data/local/tmp/models_stage';
  const srcDir = '/data/local/tmp/jav03';

  testWidgets('EP3: STT → auditJA → MT → auditPT → srt', (tester) async {
    // 1) STT (student destilado)
    final stt = Jav03SttProvider(
      '$srcDir', // mel/encoder/decoder/tokens já lá do teste anterior
      task: 'transcribe',
      promptIds: const [50258, 50266, 50359, 50363, 50257],
      files: const ['mel.onnx', 'encoder_model.int8.onnx',
                    'decoder_model.int8.onnx'],
      providerId: 'whisper-small-anime-distill',
    );
    await stt.load();
    // EP3 completo = 23 min (STT ~15 min). O trecho de 2 min valida o fluxo
    // inteiro com 1/10 do tempo — trocar para 'ep3.pcm' p/ o ep completo.
    final srcCues = await stt.transcribe('$srcDir/ep3_trecho.pcm');
    await stt.dispose();
    // ignore: avoid_print
    print('STT_OK cues=${srcCues.length}');

    // 2) auditJA (heretic por push)
    final auditor = AuditProvider('$stg/auditor.gguf');
    await auditor.load();
    final audJa = await auditor.auditJa(srcCues);
    await auditor.dispose();
    // ignore: avoid_print
    print('AUDIT_JA_OK');

    // 3) MT (Qwen anime por push)
    final mt = LlmMtProvider('$stg/Qwen3-0.6B-JA-PT-Anime-Q4_K_M.gguf',
        expectedMb: 378);
    await mt.load();
    final ptCues = <SrtCue>[];
    for (final c in audJa) {
      final t = await mt.translate(c.text, src: 'ja', tgt: 'pt');
      ptCues.add(c.withText(t));
    }
    await mt.dispose();
    // ignore: avoid_print
    print('MT_OK cues=${ptCues.length}');

    // 4) auditPT
    final auditor2 = AuditProvider('$stg/auditor.gguf');
    await auditor2.load();
    final audPt = await auditor2.auditPt(ptCues);
    await auditor2.dispose();
    // ignore: avoid_print
    print('AUDIT_PT_OK');

    // 5) salva os 4 estágios p/ inspeção
    Future<void> dump(String name, List<SrtCue> cues) async {
      final srt = SrtParser.format(cues);
      final f = File('/sdcard/Download/$name.srt');
      try {
        await f.writeAsString(srt);
      } catch (_) {
        // sem permissão: grava no dir do app
        await File('/data/local/tmp/$name.srt').writeAsString(srt);
      }
    }

    await dump('ep3_1_bruto_ja', srcCues);
    await dump('ep3_2_audit_ja', audJa);
    await dump('ep3_3_bruto_pt', ptCues);
    await dump('ep3_4_audit_pt', audPt);

    // amostra no console (o dono lê pelo logcat)
    for (var i = 0; i < ptCues.length && i < 12; i++) {
      // ignore: avoid_print
      print('L$i JA : ${srcCues[i].text.replaceAll("\n", " ")}');
      // ignore: avoid_print
      print('L$i AJ : ${audJa[i].text.replaceAll("\n", " ")}');
      // ignore: avoid_print
      print('L$i PT : ${ptCues[i].text.replaceAll("\n", " ")}');
      // ignore: avoid_print
      print('L$i AP : ${audPt[i].text.replaceAll("\n", " ")}');
    }
  });
}
