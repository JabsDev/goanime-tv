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

/// MT fake: responde '' para `blankText` (tradução falhada), traduz o resto.
class _SkipMt extends _PrefixMt {
  final String blankText;
  _SkipMt(this.blankText);
  @override
  Future<String> translate(String text,
          {required String src, required String tgt}) async =>
      text == blankText ? '' : 'PT:$text';
}

/// MT fake que lança em `boomText` (erro residual do provider).
class _BoomMt extends _PrefixMt {
  final String boomText;
  _BoomMt(this.boomText);
  @override
  Future<String> translate(String text,
          {required String src, required String tgt}) async {
    if (text == boomText) throw StateError('provider morto');
    return 'PT:$text';
  }
}

const _src2 = '1\n00:00:01,000 --> 00:00:02,000\nHello\n\n'
    '2\n00:00:03,000 --> 00:00:04,000\nWorld\n\n';

/// MT fake: responde '' (falha) para as falas em `blank`, traduz o resto.
class _BlankManyMt extends _PrefixMt {
  final Set<String> blank;
  _BlankManyMt(this.blank);
  @override
  Future<String> translate(String text,
          {required String src, required String tgt}) async =>
      blank.contains(text) ? '' : 'PT:$text';
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
      // label done inclui contagem X/Y (item 3)
      expect(mgr.state.value.message, contains('1 de 1'));
    } finally {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
    }
  });

  test('tradução vazia preserva a cue com o texto fonte (item 2)', () async {
    final jobs = await Directory.systemTemp.createTemp('jobs_fb');
    final subs = await Directory.systemTemp.createTemp('subs_fb');
    SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    try {
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranslate(
        animeKey: 'haibane', ep: 10, srcSrt: _src2, srcLang: 'en',
        mt: _SkipMt('Hello'), jobsDirForTest: jobs, subsDirForTest: subs);
      for (var i = 0; i < 100 && mgr.isBusy; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(mgr.state.value.phase, JobPhase.done);
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 10, tag: 'en-ai', subsDirForTest: subs);
      final cues = SrtParser.parse(await f!.readAsString());
      expect(cues, hasLength(2)); // cue não se descarta
      expect(cues[0].text, 'Hello'); // fallback ao texto fonte
      expect(cues[1].text, 'PT:World');
      // X=1 de Y=2 → <30%... 50% ≥30% → aviso sem "poucas"
      expect(mgr.state.value.message, contains('1 de 2'));
      expect(mgr.state.value.message, isNot(contains('poucas')));
    } finally {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
    }
  });

  test('fonte-lixo puro é descartado (não vira cue)', () async {
    final jobs = await Directory.systemTemp.createTemp('jobs_junk');
    final subs = await Directory.systemTemp.createTemp('subs_junk');
    SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    try {
      const src = '1\n00:00:01,000 --> 00:00:02,000\n!!!\n\n'
          '2\n00:00:03,000 --> 00:00:04,000\nWord\n\n';
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranslate(
        animeKey: 'haibane', ep: 11, srcSrt: src, srcLang: 'en',
        mt: _PrefixMt(), jobsDirForTest: jobs, subsDirForTest: subs);
      for (var i = 0; i < 100 && mgr.isBusy; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(mgr.state.value.phase, JobPhase.done);
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 11, tag: 'en-ai', subsDirForTest: subs);
      final cues = SrtParser.parse(await f!.readAsString());
      expect(cues, hasLength(1));
      expect(cues.single.text, 'PT:Word');
    } finally {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
    }
  });

  test('erro do MT não mata o job (cue com fallback)', () async {
    final jobs = await Directory.systemTemp.createTemp('jobs_boom');
    final subs = await Directory.systemTemp.createTemp('subs_boom');
    SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    try {
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranslate(
        animeKey: 'haibane', ep: 12, srcSrt: _src2, srcLang: 'en',
        mt: _BoomMt('World'), jobsDirForTest: jobs, subsDirForTest: subs);
      for (var i = 0; i < 100 && mgr.isBusy; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      // Antes: StateError do provider abortava o job inteiro (failed).
      expect(mgr.state.value.phase, JobPhase.done);
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 12, tag: 'en-ai', subsDirForTest: subs);
      final cues = SrtParser.parse(await f!.readAsString());
      expect(cues, hasLength(2));
      expect(cues[1].text, 'World');
    } finally {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
    }
  });

  test('0 cues não termina done: falha alta sem cache sujo', () async {
    final jobs = await Directory.systemTemp.createTemp('jobs_gate0');
    final subs = await Directory.systemTemp.createTemp('subs_gate0');
    SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    try {
      final mgr = SubtitleJobManager.instance;
      // Fonte toda lixo: traduz "tudo" mas isJunk elimina as cues.
      const junk = '1\n00:00:01,000 --> 00:00:02,000\n!!!\n\n';
      await mgr.enqueueTranslate(
        animeKey: 'haibane', ep: 13, srcSrt: junk, srcLang: 'en',
        mt: _PrefixMt(), jobsDirForTest: jobs, subsDirForTest: subs);
      for (var i = 0; i < 100 && mgr.isBusy; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(mgr.state.value.phase, JobPhase.failed);
      expect(mgr.state.value.error, contains('0 falas traduzidas'));
      expect(mgr.state.value.error, isNot(contains('#0'))); // sem stack
      expect(
          await SubtitleStore.get(
              animeKey: 'haibane', ep: 13, tag: 'en-ai',
              subsDirForTest: subs),
          isNull); // NADA salvo
    } finally {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
    }
  });

  test('<30% grava e avisa "poucas falas"', () async {
    final jobs = await Directory.systemTemp.createTemp('jobs_few');
    final subs = await Directory.systemTemp.createTemp('subs_few');
    SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    try {
      // 10 cues, fake MT traduz só 2 (resposta '' nas 8 demais).
      final sb = StringBuffer();
      for (var i = 1; i <= 10; i++) {
        sb.write(
            '$i\n00:00:${i.toString().padLeft(2, '0')},000 --> '
            '00:00:${(i + 1).toString().padLeft(2, '0')},000\nCue$i\n\n');
      }
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranslate(
        animeKey: 'haibane', ep: 14, srcSrt: sb.toString(), srcLang: 'en',
        mt: _BlankManyMt({'Cue3', 'Cue4', 'Cue5', 'Cue6', 'Cue7', 'Cue8',
            'Cue9', 'Cue10'}),
        jobsDirForTest: jobs, subsDirForTest: subs);
      for (var i = 0; i < 200 && mgr.isBusy; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(mgr.state.value.phase, JobPhase.done);
      expect(mgr.state.value.message, contains('poucas falas: 2 de 10'));
    } finally {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
    }
  });

  test('≥30% grava sem o aviso de poucas falas', () async {
    final jobs = await Directory.systemTemp.createTemp('jobs_ok');
    final subs = await Directory.systemTemp.createTemp('subs_ok');
    SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    try {
      // 10 cues, fake MT traduz 8.
      final sb = StringBuffer();
      for (var i = 1; i <= 10; i++) {
        sb.write(
            '$i\n00:00:${i.toString().padLeft(2, '0')},000 --> '
            '00:00:${(i + 1).toString().padLeft(2, '0')},000\nCue$i\n\n');
      }
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranslate(
        animeKey: 'haibane', ep: 15, srcSrt: sb.toString(), srcLang: 'en',
        mt: _BlankManyMt(const {'Cue1', 'Cue9'}),
        jobsDirForTest: jobs, subsDirForTest: subs);
      for (var i = 0; i < 200 && mgr.isBusy; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(mgr.state.value.phase, JobPhase.done);
      expect(mgr.state.value.message, contains('8 de 10'));
      expect(mgr.state.value.message, isNot(contains('poucas')));
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
