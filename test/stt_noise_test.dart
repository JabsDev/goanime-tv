import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/subtitles/sherpa_stt.dart';

/// Guarda anti-alucinação das janelas de recall do VAD: música de abertura vira
/// "…" ou sílaba repetida; isso não pode virar legenda. Fala curta/real passa.
void main() {
  group('looksLikeSttNoise', () {
    test('pontuação/elipse sozinhas = ruído', () {
      expect(looksLikeSttNoise('…'), isTrue);
      expect(looksLikeSttNoise('。'), isTrue);
      expect(looksLikeSttNoise('！？'), isTrue);
      expect(looksLikeSttNoise('  '), isTrue);
    });

    test('sílaba repetida longa = ruído', () {
      expect(looksLikeSttNoise('んんっ、んんっ！'), isTrue);
      expect(looksLikeSttNoise('ふ、ふ、ふ、ふ、ふ、ふ…'), isTrue);
      expect(looksLikeSttNoise('ああああああああ'), isTrue);
    });

    test('fala real (curta ou variada) passa', () {
      expect(looksLikeSttNoise('はい'), isFalse);
      expect(looksLikeSttNoise('なんだ…'), isFalse);
      expect(looksLikeSttNoise('すごい物音がしたから、勝手に入っちゃった。'), isFalse);
      expect(looksLikeSttNoise('れき、っ…'), isFalse);
      // repetição curta legítima não é descartada
      expect(looksLikeSttNoise('うんうん'), isFalse);
    });
  });
}
