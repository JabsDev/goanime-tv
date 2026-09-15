import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/marian_mt.dart';

class _FakeMarian implements MarianChannel {
  String? seenPrefix;
  @override
  Future<String> translate(String modelDir, String text,
      {String? targetPrefix}) async {
    seenPrefix = targetPrefix;
    return 'PT[$text]';
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('MarianMtProvider (canal Kotlin)', () {
    test('traduz por frase com prefixo de alvo', () async {
      final ch = _FakeMarian();
      final mt = MarianMtProvider('dir',
          targetPrefix: '>>por<<', channelForTest: ch);
      await mt.load();
      final out =
          await mt.translate('Hello world. Hi.', src: 'en', tgt: 'pt');
      expect(out, 'PT[Hello world.] PT[Hi.]');
      expect(ch.seenPrefix, '>>por<<');
      await mt.dispose();
    });

    test('translateSrt preserva timestamps', () async {
      final mt = MarianMtProvider('dir', channelForTest: _FakeMarian());
      await mt.load();
      const src = '1\n00:00:01,000 --> 00:00:02,000\nHello\n\n';
      final out = await mt.translateSrt(src, src: 'en', tgt: 'pt');
      expect(out, contains('00:00:01,000 --> 00:00:02,000'));
      expect(out, contains('PT[Hello]'));
      await mt.dispose();
    });

    test('translate sem load falha alto', () async {
      final mt =
          MarianMtProvider('dir', channelForTest: _FakeMarian());
      expect(() => mt.translate('hi', src: 'en', tgt: 'pt'),
          throwsA(isA<StateError>()));
    });

    test('nativo mudo vira timeout com mensagem (sem hang)', () async {
      final mt = MarianMtProvider('dir',
          channelForTest: _HangMarian(),
          translateTimeout: const Duration(milliseconds: 200));
      await mt.load();
      expect(() => mt.translate('hi', src: 'en', tgt: 'pt'),
          throwsA(isA<StateError>()));
      await mt.dispose();
    });
  });
}

class _HangMarian implements MarianChannel {
  @override
  Future<String> translate(String modelDir, String text,
          {String? targetPrefix}) =>
      Completer<String>().future;

  @override
  Future<void> dispose() async {}
}
