import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:goanime_tv/core/subtitles/llm_mt.dart';
import 'package:goanime_tv/core/subtitles/model_manager.dart';

/// Regressão do SIGABRT no EP3 (GGML_ASSERT n_tokens<=n_batch no prefill).
/// Roda no aparelho: `flutter test integration_test/mt_direct_test.dart`.
/// Modelos via HTTP local + `adb reverse` (ver ai_chain_test.dart).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MT nativo: curta + longa multibyte sem abortar', (tester) async {
    final base = await getApplicationSupportDirectory();
    Future<void> grab(String remote, String local) async {
      final dest = File('${base.path}/chain_models/$local');
      if (await dest.exists()) return;
      await ModelManager.fetchFile(
          dest: dest, url: 'http://127.0.0.1:8765/$remote');
    }

    await grab('hymt-ja-pt-q3km/model.gguf', 'hymt-ja-pt-q3km/model.gguf');
    final gguf = '${base.path}/chain_models/hymt-ja-pt-q3km/model.gguf';
    expect(await File(gguf).exists(), isTrue);

    // Manual e LENTO no emulador (~15-20 min: prefill de ~900 tokens em
    // CPU x86 emulada). Em aparelho real é minutos. Não roda no CI.
    final mt = LlmMtProvider(gguf,
        expectedMb: 907, translateTimeout: const Duration(minutes: 30));
    await mt.load();
    try {
      final short = await mt.translate('今日はとても良い天気です。',
          src: 'ja', tgt: 'pt');
      expect(short.trim().isNotEmpty, isTrue, reason: 'tradução vazia?');

      // ~1500 chars sem 。: estourava n_batch num batch único (abort).
      final longJa = List.filled(
          40, 'この物語は小さな村から始まります、主人公は勇者になることを夢見ていました')
          .join('、');
      final longOut =
          await mt.translate(longJa, src: 'ja', tgt: 'pt');
      expect(longOut.trim().isNotEmpty, isTrue,
          reason: 'tradução longa vazia?');
    } finally {
      await mt.dispose();
    }
  });
}
