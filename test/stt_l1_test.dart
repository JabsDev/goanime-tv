import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/mt_provider.dart';
import 'package:goanime_tv/core/subtitles/sherpa_stt.dart';
import 'package:goanime_tv/core/subtitles/srt_parser.dart';
import 'package:goanime_tv/core/subtitles/subtitle_job_manager.dart';
import 'package:goanime_tv/core/subtitles/subtitle_store.dart';

/// Ordem global p/ provar carga SEQUENCIAL (STT.dispose antes de MT.load).
final orderLog = <String>[];

class _FakeEngine implements SttEngine {
  @override
  Future<void> init(String modelDir, {required String task}) async {
    orderLog.add('stt.load');
  }

  @override
  Future<List<SpeechChunk>> segments(Float32List pcm) async {
    orderLog.add('stt.segments');
    return [
      SpeechChunk(1.0, Float32List(16000)),
      SpeechChunk(5.0, Float32List(32000)),
    ];
  }

  @override
  Future<String> decode(SpeechChunk chunk) async => 'Hello';

  @override
  Future<void> free() async {
    orderLog.add('stt.dispose');
  }
}

class _FakeStt extends SttProvider {
  final SttEngine engine = _FakeEngine();
  @override
  String get id => 'whisper-tiny-ja';
  @override
  Future<void> load() => engine.init('fake', task: 'translate');
  @override
  Future<List<SrtCue>> transcribe(String pcm16kPath,
      {void Function(double progress)? onProgress}) async {
    final chunks = await engine.segments(Float32List(0));
    final cues = <SrtCue>[];
    for (var i = 0; i < chunks.length; i++) {
      final text = await engine.decode(chunks[i]);
      onProgress?.call((i + 1) / chunks.length);
      cues.add(SrtCue(
          index: i + 1,
          start: Duration(milliseconds: (chunks[i].startSec * 1000).toInt()),
          end: Duration(
              milliseconds: ((chunks[i].startSec +
                          chunks[i].samples.length / 16000.0) *
                      1000)
                  .toInt()),
          text: text));
    }
    return cues;
  }

  @override
  Future<void> dispose() => engine.free();
}

class _FakeMt extends MtProvider {
  @override
  String get id => 'marian';
  @override
  Future<void> load() async {
    orderLog.add('mt.load');
  }

  @override
  Future<String> translate(String text,
          {required String src, required String tgt}) async =>
      'PT:$text';
  @override
  Future<void> dispose() async {
    orderLog.add('mt.dispose');
  }
}

Future<File> _fakeDownload(
    String url, Map<String, String> headers, String outPath) async {
  await File(outPath).writeAsBytes(const [0, 1, 2, 3]);
  return File(outPath);
}

Future<String> _fakeExtract(
    String url, Map<String, String> headers, String outPath) async {
  // 2s de silêncio PCM 16k mono (conteúdo irrelevante p/ fake).
  await File(outPath).writeAsBytes(Int16List(32000).buffer.asUint8List());
  return outPath;
}

Future<void> _waitIdle(SubtitleJobManager mgr) async {
  for (var i = 0; i < 200 && mgr.isBusy; i++) {
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  group('transcribeL1', () {
    late Directory jobs;
    late Directory subs;
    late Directory tmp;

    setUp(() async {
      jobs = await Directory.systemTemp.createTemp('jobs_l1');
      subs = await Directory.systemTemp.createTemp('subs_l1');
      tmp = await Directory.systemTemp.createTemp('tmp_l1');
      orderLog.clear();
      SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    });

    tearDown(() async {
      SubtitleStore.setClockForTest(null);
      await jobs.delete(recursive: true);
      await subs.delete(recursive: true);
      await tmp.delete(recursive: true);
    });

    test('JA cru gera PT-BR com tempos do STT', () async {
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranscribe(
        animeKey: 'haibane', ep: 1, videoUrl: 'http://x/ep1.mp4',
        sttFor: () => _FakeStt(), mt: _FakeMt(), download: _fakeDownload, extract: _fakeExtract,
        jobsDirForTest: jobs, subsDirForTest: subs, tmpDirForTest: tmp);
      await _waitIdle(mgr);
      expect(mgr.isBusy, isFalse);
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 1, tag: 'ja-ai', subsDirForTest: subs);
      expect(f, isNotNull);
      final cues = SrtParser.parse(await f!.readAsString());
      expect(cues, hasLength(2));
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 2));
      expect(cues[1].text, 'PT:Hello');
      expect(await jobs.list().toList(), isEmpty); // job file limpo
    });

    test('SEQUENCIAL: stt.dispose antes de mt.load', () async {
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranscribe(
        animeKey: 'haibane', ep: 2, videoUrl: 'http://x/ep2.mp4',
        sttFor: () => _FakeStt(), mt: _FakeMt(), download: _fakeDownload, extract: _fakeExtract,
        jobsDirForTest: jobs, subsDirForTest: subs, tmpDirForTest: tmp);
      await _waitIdle(mgr);
      expect(orderLog.indexOf('stt.dispose'),
          lessThan(orderLog.indexOf('mt.load')));
      expect(orderLog, containsAll(['stt.load', 'mt.load', 'mt.dispose']));
    });

    test('SherpaSttProvider monta cues do engine (unidade)', () async {
      final stt = SherpaSttProvider('fake', engineForTest: _FakeEngine());
      final pcm = await File('${tmp.path}/t.pcm')
          .writeAsBytes(Int16List(16000).buffer.asUint8List());
      await stt.load();
      final cues = await stt.transcribe(pcm.path);
      await stt.dispose();
      expect(cues, hasLength(2));
      expect(cues[0].start, const Duration(seconds: 1));
    });

    test('fases visíveis em ordem (nunca 0% mudo)', () async {
      final mgr = SubtitleJobManager.instance;
      final seen = <JobPhase>[];
      void listener() {
        final p = mgr.state.value.phase;
        if (seen.isEmpty || seen.last != p) seen.add(p);
      }

      mgr.state.addListener(listener);
      await mgr.enqueueTranscribe(
        animeKey: 'haibane', ep: 3, videoUrl: 'http://x/ep3.mp4',
        sttFor: () => _FakeStt(), mt: _FakeMt(), download: _fakeDownload, extract: _fakeExtract,
        jobsDirForTest: jobs, subsDirForTest: subs, tmpDirForTest: tmp);
      await _waitIdle(mgr);
      mgr.state.removeListener(listener);
      final order = [
        JobPhase.downloadingVideo,
        JobPhase.extractingAudio,
        JobPhase.loadingVoice,
        JobPhase.transcribing,
        JobPhase.loadingMt,
        JobPhase.translating,
        JobPhase.done,
      ];
      var lastIdx = -1;
      for (final p in order) {
        final idx = seen.indexOf(p);
        expect(idx, greaterThan(lastIdx), reason: 'fase $p fora de ordem');
        lastIdx = idx;
      }
    });
    test('falha vira failed com mensagem PT-BR (não trava no 0%)', () async {
      final mgr = SubtitleJobManager.instance;
      await mgr.enqueueTranscribe(
        animeKey: 'haibane', ep: 4, videoUrl: 'http://x/ep4.mp4',
        sttFor: () => _FakeStt(), mt: _FakeMt(),
        download: (_, __, ___) =>
            throw const SocketException('sem rede'),
        extract: _fakeExtract,
        jobsDirForTest: jobs, subsDirForTest: subs, tmpDirForTest: tmp);
      await _waitIdle(mgr);
      expect(mgr.state.value.phase, JobPhase.failed);
      expect(mgr.state.value.error, contains('internet'));
    });

    test('áudio-only pula o download do vídeo cheio', () async {
      final mgr = SubtitleJobManager.instance;
      var downloadCalled = false;
      final audio =
          await File('${tmp.path}/only.aac').writeAsBytes(const [9, 9]);
      await mgr.enqueueTranscribe(
        animeKey: 'haibane', ep: 5, videoUrl: 'http://x/ep5.m3u8',
        sttFor: () => _FakeStt(), mt: _FakeMt(),
        download: (_, __, ___) async {
          downloadCalled = true;
          throw StateError('não deveria baixar vídeo');
        },
        extract: _fakeExtract,
        audioOnlyForTest: () async => audio,
        jobsDirForTest: jobs, subsDirForTest: subs, tmpDirForTest: tmp);
      await _waitIdle(mgr);
      expect(downloadCalled, isFalse);
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 5, tag: 'ja-ai', subsDirForTest: subs);
      expect(f, isNotNull);
    });
  });
}
