import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/marian_mt.dart';

const _vocabYml = '''
"<s>": 0
"<pad>": 1
"</s>": 2
"<unk>": 3
"▁Hello": 4
"▁world": 5
"▁Olá": 6
"▁mundo": 7
"!": 8
''';

/// Sessão fake: emite a sequência [script] por sentença (reseta no bos).
class _FakeSession implements MarianSession {
  final List<int> script;
  int _step = 0;
  _FakeSession(this.script);

  @override
  Future<List<double>> stepLogits(
      List<int> encoderIds, List<int> decoderIds) async {
    if (decoderIds.length == 1) _step = 0; // nova sentença
    final next = _step < script.length ? script[_step++] : 2; // eos
    return List.generate(9, (i) => i == next ? 10.0 : -10.0);
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('MarianVocab', () {
    test('parse + encode/decode round-trip', () {
      final v = MarianVocab.parse(_vocabYml);
      expect(v.bosId, 0);
      expect(v.eosId, 2);
      expect(v.encode('Hello world!'), [4, 5, 8]);
      expect(v.decode([0, 6, 7, 8, 2]), 'Olá mundo!');
    });

    test('desconhecida vira unk sem quebrar', () {
      final v = MarianVocab.parse(_vocabYml);
      expect(v.encode('xyz'), isNotEmpty);
    });
  });

  group('MarianMtProvider', () {
    test('greedy emite script e para no eos', () async {
      final mt = MarianMtProvider('unused',
          sessionForTest: _FakeSession([6, 7]), vocabForTest: _vocabYml);
      await mt.load();
      expect(await mt.translate('Hello world', src: 'en', tgt: 'pt'),
          'Olá mundo');
      await mt.dispose();
    });

    test('chunk por frase (2 sentenças = 2 chamadas de sessão)', () async {
      var calls = 0;
      final mt = MarianMtProvider(
          'unused',
          sessionForTest: _FakeSession([6, 7]),
          vocabForTest: _vocabYml);
      await mt.load();
      final out =
          await mt.translate('Hello world. Hello world.', src: 'en', tgt: 'pt');
      calls = out.split('Olá mundo').length - 1;
      expect(calls, 2);
      await mt.dispose();
    });

    test('translate sem load falha alto', () async {
      final mt = MarianMtProvider('unused',
          sessionForTest: _FakeSession([]), vocabForTest: _vocabYml);
      expect(() => mt.translate('hi', src: 'en', tgt: 'pt'),
          throwsA(isA<StateError>()));
    });
  });
}
