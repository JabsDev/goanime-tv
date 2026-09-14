import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/nllb_mt.dart';

class _FakeNllb implements NllbChannel {
  final List<String> seenSrc = [];
  @override
  Future<String> translate(String modelDir, String text,
      {required String srcLang, required String tgtLang}) async {
    seenSrc.add('$srcLang>$tgtLang');
    return 'PT[$text]';
  }

  @override
  Future<void> dispose() async {}
}

const _strong =
    AiCapability(isLowEndForTest: _notLow, freeBytesForTest: _plenty);
const _weak = AiCapability(isLowEndForTest: _low, freeBytesForTest: _plenty);
const _full =
    AiCapability(isLowEndForTest: _notLow, freeBytesForTest: _little);

Future<bool> _notLow() async => false;
Future<bool> _low() async => true;
Future<int> _plenty() async => 4 * 1024 * 1024 * 1024;
Future<int> _little() async => 100;

void main() {
  group('AiCapability gating L2', () {
    test('forte + disco = pode', () async {
      expect(await _strong.canUseFull(), isTrue);
    });
    test('low-end bloqueia', () async {
      expect(await _weak.canUseFull(), isFalse);
    });
    test('disco cheio bloqueia', () async {
      expect(await _full.canUseFull(), isFalse);
    });
  });

  group('NllbMtProvider', () {
    test('jpn→por direto por frase', () async {
      final ch = _FakeNllb();
      final mt = NllbMtProvider('dir',
          channelForTest: ch, capabilityForTest: _strong);
      await mt.load();
      final out =
          await mt.translate('こんにちは。元気？', src: 'ja', tgt: 'pt');
      expect(out, contains('PT['));
      expect(ch.seenSrc, everyElement('jpn_Jpan>por_Latn'));
      await mt.dispose();
    });

    test('load em aparelho fraco falha alto', () async {
      final mt = NllbMtProvider('dir',
          channelForTest: _FakeNllb(), capabilityForTest: _weak);
      expect(() => mt.load(), throwsA(isA<StateError>()));
    });

    test('translate sem load falha alto', () async {
      final mt = NllbMtProvider('dir',
          channelForTest: _FakeNllb(), capabilityForTest: _strong);
      expect(() => mt.translate('x', src: 'ja', tgt: 'pt'),
          throwsA(isA<StateError>()));
    });
  });
}
