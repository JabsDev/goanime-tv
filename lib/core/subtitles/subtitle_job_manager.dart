import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_extract.dart';
import 'mt_provider.dart';
import 'srt_parser.dart';
import 'subtitle_store.dart';

/// Job batch de legenda IA (nunca tempo-real): fila FIFO, 1 job por vez,
/// progresso, cancelamento e resume após kill via job file em disco.
/// Rotas: `translateOnly` (Rota S, sem Whisper) e `transcribeL1` (Fase 2).
class SubtitleJobManager {
  SubtitleJobManager._();
  static final SubtitleJobManager instance = SubtitleJobManager._();

  final _queue = <_Job>[];
  _Job? _current;
  bool get isBusy => _current != null;

  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<String?> status = ValueNotifier<String?>(null);

  Future<Directory> _jobsDir({Directory? forTest}) async {
    if (forTest != null) return forTest;
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/subs_jobs');
  }

  Future<void> enqueueTranslate({
    required String animeKey,
    required int ep,
    required String srcSrt,
    required String srcLang,
    required MtProvider mt,
    Directory? jobsDirForTest,
    Directory? subsDirForTest,
  }) async {
    final dir = await _jobsDir(forTest: jobsDirForTest);
    await dir.create(recursive: true);
    final job = _Job.translate(
      animeKey: animeKey,
      ep: ep,
      srcSrt: srcSrt,
      srcLang: srcLang,
      mt: mt,
      jobsDir: dir,
      subsDirForTest: subsDirForTest,
    );
    await job.save();
    _queue.add(job);
    _pump();
  }

  /// L1: JA cru → PCM (Kotlin) → STT translate ja→en → dispose STT → MT en→pt.
  /// `extract`/`sttFor`/`mtFor` injetáveis p/ teste sem nativo.
  Future<void> enqueueTranscribe({
    required String animeKey,
    required int ep,
    required String videoUrl,
    Map<String, String> headers = const {},
    required SttProvider Function() sttFor,
    required MtProvider mt,
    Future<String> Function(String url, Map<String, String> headers, String outPath)? extract,
    Directory? jobsDirForTest,
    Directory? subsDirForTest,
    Directory? tmpDirForTest,
  }) async {
    final dir = await _jobsDir(forTest: jobsDirForTest);
    await dir.create(recursive: true);
    final job = _Job.transcribe(
      animeKey: animeKey,
      ep: ep,
      videoUrl: videoUrl,
      headers: headers,
      sttFor: sttFor,
      mt: mt,
      extract: extract,
      jobsDir: dir,
      subsDirForTest: subsDirForTest,
      tmpDirForTest: tmpDirForTest,
    );
    await job.save();
    _queue.add(job);
    _pump();
  }

  void _pump() {
    if (_current != null || _queue.isEmpty) return;
    _current = _queue.removeAt(0);
    _run(_current!);
  }

  Future<void> _run(_Job job) async {
    try {
      if (job.kind == 'transcribe') {
        await _runTranscribe(job);
      } else {
        await _runTranslate(job);
      }
    } catch (e) {
      debugPrint('[SubtitleJob] fail: $e');
      status.value = 'Falhou';
    } finally {
      _current = null;
      _pump(); // FIFO: próximo da fila
    }
  }

  Future<void> _finish(_Job job, String tag, String srt, String srcHash) async {
    await SubtitleStore.put(
      animeKey: job.animeKey,
      ep: job.ep,
      tag: tag,
      srt: srt,
      srcHash: srcHash,
      subsDirForTest: job.subsDirForTest,
    );
    await SubtitleStore.pruneExpired(subsDirForTest: job.subsDirForTest);
    await job.delete();
    status.value = 'Pronta';
    progress.value = 1;
  }

  Future<void> _runTranslate(_Job job) async {
    status.value = 'Traduzindo…';
    progress.value = 0;
    final cues = SrtParser.parse(job.srcSrt);
    final total = cues.length;
    final out = <SrtCue>[];
    for (var i = 0; i < cues.length; i++) {
      if (job.cancelled) {
        status.value = 'Cancelado';
        return;
      }
      out.add(cues[i].withText(
          await job.mt.translate(cues[i].text, src: job.srcLang, tgt: 'pt')));
      progress.value = total == 0 ? 1 : (i + 1) / total;
      if (i % 10 == 0) await job.save(progress: progress.value);
    }
    if (!job.cancelled) {
      await _finish(job, '${job.srcLang}-ai', SrtParser.format(out),
          SubtitleStore.sha256Of(job.srcSrt));
    } else {
      status.value = 'Cancelado';
    }
  }

  /// Carga SEQUENCIAL obrigatória: STT.dispose() antes de MT.load().
  Future<void> _runTranscribe(_Job job) async {
    status.value = 'Extraindo áudio…';
    progress.value = 0;
    final tmp = job.tmpDirForTest ?? await Directory.systemTemp.createTemp('stt');
    final pcmPath = '${tmp.path}/ep${job.ep}.pcm';
    List<SrtCue> enCues = [];
    final stt = job.sttFor!();
    try {
      final extract = job.extract ??
          (String url, Map<String, String> h, String out) =>
              AudioExtract.extractPcm16k(
                  url: url, headers: h, outPath: out);
      await extract(job.videoUrl, job.headers, pcmPath);
      if (job.cancelled) {
        status.value = 'Cancelado';
        return;
      }
      status.value = 'Transcrevendo…';
      await stt.load();
      try {
        enCues = await stt.transcribe(pcmPath,
            onProgress: (p) => progress.value = p * 0.7);
      } finally {
        await stt.dispose(); // NUNCA ambos residentes
      }
      if (job.cancelled) {
        status.value = 'Cancelado';
        return;
      }
      status.value = 'Traduzindo…';
      final mt = job.mt;
      await mt.load();
      try {
        final out = <SrtCue>[];
        for (var i = 0; i < enCues.length; i++) {
          if (job.cancelled) {
            status.value = 'Cancelado';
            return;
          }
          out.add(enCues[i].withText(
              await mt.translate(enCues[i].text, src: 'en', tgt: 'pt')));
          progress.value = 0.7 + 0.3 * (i + 1) / (enCues.isEmpty ? 1 : enCues.length);
        }
        await _finish(job, 'ja-ai', SrtParser.format(out),
            SubtitleStore.sha256Of(job.videoUrl));
      } finally {
        await mt.dispose();
      }
    } finally {
      try {
        await File(pcmPath).delete();
      } catch (_) {}
    }
  }

  void cancelCurrent() => _current?.cancelled = true;

  /// Resume após kill: re-enfileira jobs com arquivo pendente.
  Future<void> resumePending({
    required MtProvider Function(String mtId) mtFor,
    SttProvider Function(String sttId)? sttFor,
    Directory? jobsDirForTest,
    Directory? subsDirForTest,
  }) async {
    final dir = await _jobsDir(forTest: jobsDirForTest);
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.job.json')) continue;
      try {
        final m = jsonDecode(await e.readAsString()) as Map;
        final kind = m['kind'] as String? ?? 'translate';
        if (kind == 'transcribe' && sttFor != null) {
          _queue.add(_Job.transcribe(
            animeKey: m['animeKey'] as String,
            ep: (m['ep'] as num).toInt(),
            videoUrl: m['videoUrl'] as String,
            headers: Map<String, String>.from(m['headers'] as Map? ?? {}),
            sttFor: () => sttFor(m['sttId'] as String? ?? 'whisper-tiny-ja'),
            mt: mtFor(m['mtId'] as String? ?? 'marian'),
            jobsDir: dir,
            subsDirForTest: subsDirForTest,
            file: e,
          ));
        } else if (kind == 'translate') {
          _queue.add(_Job.translate(
            animeKey: m['animeKey'] as String,
            ep: (m['ep'] as num).toInt(),
            srcSrt: m['srcSrt'] as String,
            srcLang: m['srcLang'] as String,
            mt: mtFor(m['mtId'] as String? ?? 'passthrough'),
            jobsDir: dir,
            subsDirForTest: subsDirForTest,
            file: e,
          ));
        } else {
          await e.delete();
        }
      } catch (_) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    _pump();
  }

  /// @visibleForTesting
  int queueLengthForTest() => _queue.length;
}

class _Job {
  final String kind; // 'translate' | 'transcribe'
  final String animeKey;
  final int ep;
  final String srcSrt;
  final String srcLang;
  final String videoUrl;
  final Map<String, String> headers;
  final SttProvider Function()? sttFor;
  final Future<String> Function(
      String url, Map<String, String> headers, String outPath)? extract;
  final MtProvider mt;
  final Directory jobsDir;
  final Directory? subsDirForTest;
  final Directory? tmpDirForTest;
  File? file;
  bool cancelled = false;

  _Job.translate({
    required this.animeKey,
    required this.ep,
    required this.srcSrt,
    required this.srcLang,
    required this.mt,
    required this.jobsDir,
    this.subsDirForTest,
    this.file,
  })  : kind = 'translate',
        videoUrl = '',
        headers = const {},
        sttFor = null,
        extract = null,
        tmpDirForTest = null;

  _Job.transcribe({
    required this.animeKey,
    required this.ep,
    required this.videoUrl,
    required this.headers,
    required SttProvider Function() sttFor,
    required this.mt,
    required this.jobsDir,
    this.extract,
    this.subsDirForTest,
    this.tmpDirForTest,
    this.file,
  })  : kind = 'transcribe',
        srcSrt = '',
        srcLang = 'en',
        sttFor = sttFor;

  String get _sttId {
    try {
      return sttFor?.call().id ?? 'whisper-tiny-ja';
    } catch (_) {
      return 'whisper-tiny-ja';
    }
  }

  Future<void> save({double? progress}) async {
    file ??= File(
        '${jobsDir.path}/${SubtitleStore.sanitizeKey(animeKey)}_ep$ep.${DateTime.now().millisecondsSinceEpoch}.job.json');
    await file!.writeAsString(jsonEncode({
      'kind': kind,
      'animeKey': animeKey,
      'ep': ep,
      'srcSrt': srcSrt,
      'srcLang': srcLang,
      'videoUrl': videoUrl,
      'headers': headers,
      'sttId': _sttId,
      'mtId': mt.id,
      'progress': progress ?? 0,
    }));
  }

  Future<void> delete() async {
    try {
      await file?.delete();
    } catch (_) {}
  }
}
