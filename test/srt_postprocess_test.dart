import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/srt_parser.dart';

void main() {
  group('SrtParser pós-processamento (QA sensevoice/VAD)', () {
    test('frase do screenshot (131 chars) vira 2 cues ≤42 chars/linha', () {
      const long =
          'O lugar onde as pessoas não vivem parece realmente ser como um '
          '“palácio dos fantasmas”. De fato, parece ser esse andar, não é?';
      final out = SrtParser.postprocess([
        const SrtCue(
            index: 1,
            start: Duration(seconds: 96),
            end: Duration(seconds: 103),
            text: long),
      ], fromStt: true);
      expect(out.length, 2);
      for (final c in out) {
        final lines = c.text.split('\n');
        expect(lines.length, lessThanOrEqualTo(2));
        expect(lines.every((l) => l.length <= SrtParser.maxLineChars), isTrue);
      }
      // nada perdido
      expect(out.map((c) => c.text.replaceAll('\n', ' ')).join(' '), long);
    });

    test('frase média cabe em 2 linhas balanceadas', () {
      const mid = 'O lugar parece um palácio dos fantasmas, não é?';
      final lines = SrtParser.rewrap(mid).split('\n');
      expect(lines.length, lessThanOrEqualTo(2));
      expect(lines.every((l) => l.length <= SrtParser.maxLineChars), isTrue);
    });

    test('cue longa divide em N cues com tempos progressivos', () {
      final cues = [
        const SrtCue(
            index: 1,
            start: Duration(seconds: 10),
            end: Duration(seconds: 20),
            text:
                'Primeira frase curta aqui. Segunda frase que deveria aparecer bem depois e não junto. Terceira frase para forçar a divisão em mais de uma legenda de tela.'),
      ];
      final out = SrtParser.postprocess(cues, fromStt: true);
      expect(out.length, greaterThan(1));
      // 2ª parte não começa junto da 1ª (era o "adiantada")
      expect(out[1].start, greaterThan(out[0].start + const Duration(milliseconds: 900)));
      expect(out.every((c) => c.text.split('\n').length <= 2), isTrue);
      expect(
          out.every((c) =>
              c.text.split('\n').every((l) => l.length <= SrtParser.maxLineChars)),
          isTrue);
      // ordem temporal preservada
      for (var i = 1; i < out.length; i++) {
        expect(out[i].start, greaterThanOrEqualTo(out[i - 1].end));
      }
    });

    test('STT aplica +150ms; Rota S preserva tempos da fonte', () {
      const cue = SrtCue(
          index: 1,
          start: Duration(seconds: 5),
          end: Duration(seconds: 7),
          text: 'Oi');
      final stt = SrtParser.postprocess([cue], fromStt: true).single;
      expect(stt.start, const Duration(milliseconds: 5150));
      final src = SrtParser.postprocess([cue]).single;
      expect(src.start, const Duration(seconds: 5));
    });
  });
}
