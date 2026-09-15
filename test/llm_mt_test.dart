import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/llm_mt.dart';

class _FakeLlm implements LlmChannel {
  String? seenSrc;
  String? seenTgt;
  String? seenPath;
  @override
  Future<String> translate(String modelPath, String text,
      {required String srcLang, required String tgtLang}) async {
    seenPath = modelPath;
    seenSrc = srcLang;
    seenTgt = tgtLang;
    return 'PT[$text]';
  }

  @override
  Future<void> dispose() async {}
}

class _HangLlm implements LlmChannel {
  @override
  Future<String> translate(String modelPath, String text,
          {required String srcLang, required String tgtLang}) =>
      Completer<String>().future;

  @override
  Future<void> dispose() async {}
}

void main() {
  group('LlmMtProvider (canal llama.cpp)', () {
    test('JA→PT passa códigos e modelPath', () async {
      final ch = _FakeLlm();
      final mt = LlmMtProvider('/m/model.gguf', channelForTest: ch);
      await mt.load();
      final out = await mt.translate('こんにちは', src: 'ja', tgt: 'pt');
      expect(out, 'PT[こんにちは]');
      expect(ch.seenSrc, 'ja');
      expect(ch.seenTgt, 'pt');
      expect(ch.seenPath, '/m/model.gguf');
      await mt.dispose();
    });

    test('mesmo idioma devolve texto (sem nativo)', () async {
      final mt = LlmMtProvider('x', channelForTest: _FakeLlm());
      await mt.load();
      expect(await mt.translate('hi', src: 'en', tgt: 'en'), 'hi');
      await mt.dispose();
    });

    test('par fora de ja/en/pt/es falha alto', () async {
      final mt = LlmMtProvider('x', channelForTest: _FakeLlm());
      await mt.load();
      expect(() => mt.translate('hi', src: 'de', tgt: 'pt'),
          throwsA(isA<StateError>()));
      await mt.dispose();
    });

    test('nativo mudo vira timeout com mensagem', () async {
      final mt = LlmMtProvider('x',
          channelForTest: _HangLlm(),
          translateTimeout: const Duration(milliseconds: 200));
      await mt.load();
      expect(() => mt.translate('hi', src: 'ja', tgt: 'pt'),
          throwsA(isA<StateError>()));
      await mt.dispose();
    });
  });
}
