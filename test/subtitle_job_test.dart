import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/mt_provider.dart';
import 'package:goanime_tv/core/subtitles/srt_parser.dart';
import 'package:goanime_tv/core/subtitles/subtitle_job_manager.dart';
import 'package:goanime_tv/core/subtitles/subtitle_store.dart';

class _PrefixMt extends MtProvider {
  @override
  String get id => 'test-mt';
  @override
  Future<void> load() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<String> translate(String text,
          {required String src, required String tgt}) async =>
      'PT:$text';
}

void main() {
  test('translateOnly preserva timestamps e traduz texto', () async {
    final jobs = await Directory.systemTemp.createTemp('jobs_test');
    final subs = await Directory.systemTemp.createTemp('subs_job_test');
    SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    try {
      const src = '1\n00:00:01,000 --> 00:00:02,000\nHello\n\n';
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranslate(
        animeKey: 'haibane', ep: 1, srcSrt: src, srcLang: 'en',
        mt: _PrefixMt(), jobsDirForTest: jobs, subsDirForTest: subs);
      for (var i = 0; i < 100 && mgr.isBusy; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(mgr.isBusy, isFalse);
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 1, tag: 'en-ai', subsDirForTest: subs);
      expect(f, isNotNull);
      final cues = SrtParser.parse(await f!.readAsString());
      expect(cues.single.text, 'PT:Hello');
      expect(cues.single.start, const Duration(seconds: 1));
      // job file removido após concluir
      expect(await jobs.list().toList(), isEmpty);
    } finally {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
    }
  });

  group('friendlyError LLM (EP3)', () {
    test('CORRUPT/OOM/legada viram PT-BR sem stack', () {
      for (final e in [
        StateError('LLM_CORRUPT: /m/model.gguf'),
        StateError('LLM_OOM: /m/model.gguf'),
        StateError('falha ao carregar /m/model.gguf'),
      ]) {
        final msg = SubtitleJobManager.friendlyError(e);
        expect(msg, isNot(contains('model.gguf')));
        expect(msg, isNot(contains('#0')));
      }
      expect(SubtitleJobManager.friendlyError(StateError('LLM_CORRUPT: x')),
          contains('corrompido'));
      expect(SubtitleJobManager.friendlyError(StateError('LLM_OOM: x')),
          contains('Memória'));
    });
  });
}
