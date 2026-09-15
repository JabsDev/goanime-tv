import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/lfm_mt.dart';
import 'package:goanime_tv/core/subtitles/mt_provider.dart';

class _FakeLfm implements LfmChannel {
  String? seenSrc;
  String? seenTgt;
  @override
  Future<String> translate(String modelDir, String text,
      {required String srcLang, required String tgtLang}) async {
    seenSrc = srcLang;
    seenTgt = tgtLang;
    return 'EN[$text]';
  }

  @override
  Future<void> dispose() async {}
}

class _HangLfm implements LfmChannel {
  @override
  Future<String> translate(String modelDir, String text,
          {required String srcLang, required String tgtLang}) =>
      Completer<String>().future;

  @override
  Future<void> dispose() async {}
}

void main() {
  group('LfmMtProvider (canal Kotlin)', () {
    test('JA→EN com códigos do modelo', () async {
      final ch = _FakeLfm();
      final mt = LfmMtProvider('dir', channelForTest: ch);
      await mt.load();
      final out = await mt.translate('こんにちは', src: 'ja', tgt: 'en');
      expect(out, 'EN[こんにちは]');
      expect(ch.seenSrc, 'ja');
      expect(ch.seenTgt, 'en');
      await mt.dispose();
    });

    test('par fora de JA↔EN falha alto', () async {
      final mt = LfmMtProvider('dir', channelForTest: _FakeLfm());
      await mt.load();
      expect(() => mt.translate('hi', src: 'en', tgt: 'pt'),
          throwsA(isA<StateError>()));
      await mt.dispose();
    });

    test('nativo mudo vira timeout com mensagem', () async {
      final mt = LfmMtProvider('dir',
          channelForTest: _HangLfm(),
          translateTimeout: const Duration(milliseconds: 200));
      await mt.load();
      expect(() => mt.translate('hi', src: 'ja', tgt: 'en'),
          throwsA(isA<StateError>()));
      await mt.dispose();
    });
  });

  group('ChainedMtProvider', () {
    test('encadeia JA→EN→PT em ordem', () async {
      final calls = <String>[];
      final a = _OrderMt('A', calls);
      final b = _OrderMt('B', calls);
      final chain = ChainedMtProvider(
          [MtStage(a, 'ja', 'en'), MtStage(b, 'en', 'pt')]);
      expect(chain.id, 'order-A+order-B');
      await chain.load();
      final out = await chain.translate('x', src: 'ja', tgt: 'pt');
      expect(out, 'B(A(x))');
      expect(calls, ['load-A', 'load-B', 'tr-A:ja->en', 'tr-B:en->pt']);
      await chain.dispose();
      expect(calls.sublist(4), ['dispose-A', 'dispose-B']);
    });
  });
}

class _OrderMt extends MtProvider {
  final String tag;
  final List<String> calls;
  _OrderMt(this.tag, this.calls);
  @override
  String get id => 'order-$tag';
  @override
  Future<void> load() async {
    calls.add('load-$tag');
  }

  @override
  Future<String> translate(String text,
      {required String src, required String tgt}) async {
    calls.add('tr-$tag:$src->$tgt');
    return '$tag($text)';
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose-$tag');
  }
}
