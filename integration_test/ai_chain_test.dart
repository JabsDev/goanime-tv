import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:goanime_tv/core/subtitles/llm_mt.dart';
import 'package:goanime_tv/core/subtitles/model_manager.dart';
import 'package:goanime_tv/core/subtitles/sherpa_stt.dart';
import 'package:goanime_tv/core/subtitles/subtitle_job_manager.dart';

/// Reproduz a cadeia real STT (SenseVoice) → dispose → MT (Hy-MT2 Q3)
/// num aparelho de verdade. Modelos + mp4 entram via `adb push` em
/// getExternalStorageDirectory()/chain_models (sem permissão extra).
/// Se o processo morrer no meio, o `flutter test` falha por disconnect
/// e o logcat (capturado no host) mostra a causa (LMK/SIGSEGV/ART abort).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cadeia STT→MT em aparelho real', (tester) async {
    // Modelos via HTTP local (host) + `adb reverse`: baixa com o próprio
    // fetchFile do app p/ o dir interno (sem permissão, sem run-as).
    final base = await getApplicationSupportDirectory();
    final ext = base;
    expect(ext.path.isNotEmpty, isTrue);
    Future<void> grab(String remote, String local) async {
      final dest = File('${ext.path}/chain_models/$local');
      if (await dest.exists()) return;
      await ModelManager.fetchFile(
          dest: dest, url: 'http://127.0.0.1:8765/$remote');
    }

    await grab('sensevoice-ja/model.int8.onnx',
        'sensevoice-ja/model.int8.onnx');
    await grab('sensevoice-ja/tokens.txt', 'sensevoice-ja/tokens.txt');
    await grab('hymt-ja-pt-q3km/model.gguf', 'hymt-ja-pt-q3km/model.gguf');
    await grab('sample_ja.mp4', 'sample_ja.mp4');
    final sttDir = '${ext.path}/chain_models/sensevoice-ja';
    final gguf = '${ext.path}/chain_models/hymt-ja-pt-q3km/model.gguf';
    final src = File('${ext.path}/chain_models/sample_ja.mp4');
    expect(await File('$sttDir/model.int8.onnx').exists(), isTrue,
        reason: 'download via adb reverse antes');
    expect(await File(gguf).exists(), isTrue);
    expect(await src.exists(), isTrue);

    final stt = SherpaSttProvider(sttDir,
        task: 'transcribe', sttKind: 'sensevoice');
    final mt = LlmMtProvider(gguf, expectedMb: 907);

    final jobsDir =
        await Directory('${ext.path}/chain_jobs').create(recursive: true);
    final subsDir =
        await Directory('${ext.path}/chain_subs').create(recursive: true);
    final tmpDir =
        await Directory('${ext.path}/chain_tmp').create(recursive: true);

    final mgr = SubtitleJobManager.instance;
    final t0 = DateTime.now();
    void mark(String m) =>
        // ignore: avoid_print
        print('[CHAIN ${DateTime.now().difference(t0).inSeconds}s] $m');

    // MT direto ANTES da cadeia: força nativeLoad + generate com multibyte.
    // Frase curta (cue típica) + texto longo sem 。 (teto 128 tokens corta
    // no meio de char JA — pré-fix abortava a ART aqui).
    mark('MT direto: frase curta JA→PT');
    await mt.load();
    final short = await mt.translate('今日はとても良い天気です。',
        src: 'ja', tgt: 'pt');
    mark('MT curto OK: $short');
    final longJa = List.filled(40, 'この物語は小さな村から始まります、主人公は勇者になることを夢見ていました').join('、');
    mark('MT direto: texto longo (${longJa.length} chars)');
    final longOut = await mt.translate(longJa, src: 'ja', tgt: 'pt');
    mark('MT longo OK (${longOut.length} chars): '
        '${longOut.substring(0, longOut.length.clamp(0, 120))}');
    await mt.dispose();

    mark('enfileirando (stt=sensevoice mt=q3)');
    mgr.state.addListener(() {
      final s = mgr.state.value;
      mark('fase=${s.phase.name} prog=${s.progress.toStringAsFixed(2)} '
          'msg=${s.message} det=${s.detail}');
    });
    await mgr.enqueueTranscribe(
      animeKey: 'chain',
      ep: 1,
      videoUrl: 'http://x/ep.mp4',
      sttFor: () => stt,
      mt: mt,
      download: (url, h, out) => src.copy(out),
      jobsDirForTest: jobsDir,
      subsDirForTest: subsDir,
      tmpDirForTest: tmpDir,
    );
    final sw = Stopwatch()..start();
    while (mgr.isBusy && sw.elapsed < const Duration(minutes: 40)) {
      await Future.delayed(const Duration(seconds: 5));
    }
    expect(mgr.isBusy, isFalse, reason: 'job travou além de 40 min');
    mark('fim fase=${mgr.state.value.phase.name} '
        'erro=${mgr.state.value.error}');
    // Prova mecânica do pipeline: SRT salvo. (Contagem de falas não é
    // assertiva aqui: TTS robótico rende 0 cues no SenseVoice; com fala
    // real há cues — o MT em si é coberto pelo mt_direct_test.)
    var srtFound = false;
    await for (final e in subsDir.list()) {
      if (e is File && e.path.endsWith('.srt')) {
        srtFound = true;
        final text = await e.readAsString();
        mark('srt=${e.path.split('/').last} bytes=${text.length}');
      }
    }
    expect(srtFound, isTrue, reason: 'SRT não foi salvo?');
    expect(mgr.state.value.phase, JobPhase.done,
        reason: 'erro: ${mgr.state.value.error}');
  });
}
