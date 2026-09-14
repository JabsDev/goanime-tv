import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_extract.dart';
import 'model_manager.dart';
import 'mt_provider.dart';
import 'srt_parser.dart';
import 'subtitle_store.dart';

/// Fase visível do job (a UI mostra message + progress + detail; nunca 0%
/// mudo — cada fase explica o que está acontecendo e o que pode demorar).
enum JobPhase {
  idle,
  downloadingVideo,
  extractingAudio,
  loadingVoice,
  transcribing,
  loadingMt,
  translating,
  saving,
  done,
  failed,
  cancelled,
}

class JobState {
  final JobPhase phase;
  final double progress;
  final String message;
  final String detail;
  final String? error;

  const JobState({
    this.phase = JobPhase.idle,
    this.progress = 0,
    this.message = '',
    this.detail = '',
    this.error,
  });
}

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

  /// Estado granular p/ a tela dedicada (fase + mensagem + detalhe + erro).
  final ValueNotifier<JobState> state =
      ValueNotifier<JobState>(const JobState());

  void _set(JobPhase phase, double progressValue, String message,
      {String detail = '', String? error}) {
    progress.value = progressValue;
    status.value = message;
    state.value = JobState(
        phase: phase,
        progress: progressValue,
        message: message,
        detail: detail,
        error: error);
  }

  /// Erro técnico → frase PT-BR acionável (a tela mostra + botão Tentar).
  static String friendlyError(Object e) {
    final s = e.toString();
    if (e is SocketException) {
      return 'Sem internet. Verifique a rede e tente de novo.';
    }
    if (s.contains('404')) {
      return 'Vídeo indisponível (erro 404). A fonte pode ter saído do ar.';
    }
    if (s.contains('403')) {
      return 'Fonte recusou o acesso (erro 403). Tente outra fonte.';
    }
    if (s.contains('Modelo só baixa no Wi-Fi')) {
      return 'Modelo só baixa no Wi-Fi. Conecte-se e tente de novo.';
    }
    if (s.contains('Modelo de ') || s.contains('NLLB exige')) {
      return s.replaceAll(RegExp(r'^.*Exception: '), '');
    }
    if (s.contains('sem track de áudio')) {
      return 'Vídeo sem faixa de áudio. Tente outra fonte.';
    }
    if (s.contains('Timeout') || s.contains('timed out')) {
      return 'Tempo esgotado na rede. Tente de novo.';
    }
    final short = s.replaceAll(RegExp(r'^.*Exception: '), '');
    return 'Falhou: ${short.length > 120 ? '${short.substring(0, 120)}…' : short}';
  }

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

  /// L1: JA cru → baixa vídeo (com %) → PCM local → STT → dispose → MT.
  /// `download`/`extract`/`sttFor` injetáveis p/ teste sem nativo.
  Future<void> enqueueTranscribe({
    required String animeKey,
    required int ep,
    required String videoUrl,
    Map<String, String> headers = const {},
    required SttProvider Function() sttFor,
    required MtProvider mt,
    Future<File> Function(String url, Map<String, String> headers, String outPath)? download,
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
      download: download,
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
      await job.delete(); // falhou: não resume (re-tentativa é manual)
      _set(JobPhase.failed, progress.value, 'Falhou', error: friendlyError(e));
    } finally {
      _current = null;
      _pump(); // FIFO: próximo da fila
    }
  }

  bool _checkCancel(_Job job) {
    if (!job.cancelled) return false;
    _set(JobPhase.cancelled, progress.value, 'Cancelado');
    return true;
  }

  Future<void> _finish(_Job job, String tag, String srt, String srcHash) async {
    _set(JobPhase.saving, 0.98, 'Salvando legenda…');
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
    _set(JobPhase.done, 1, 'Legenda pronta');
  }

  Future<void> _runTranslate(_Job job) async {
    _set(JobPhase.loadingMt, 0, 'Carregando tradução…',
        detail: 'pode demorar ~1 min na 1ª vez');
    await job.mt.load();
    final cues = SrtParser.parse(job.srcSrt);
    final total = cues.length;
    final out = <SrtCue>[];
    for (var i = 0; i < cues.length; i++) {
      if (_checkCancel(job)) return;
      out.add(cues[i].withText(
          await job.mt.translate(cues[i].text, src: job.srcLang, tgt: 'pt')));
      final p = total == 0 ? 1.0 : (i + 1) / total;
      _set(JobPhase.translating, 0.05 + 0.9 * p, 'Traduzindo…',
          detail: total == 0 ? '' : '${i + 1}/$total falas');
      if (i % 10 == 0) await job.save(progress: p);
    }
    try {
      if (!_checkCancel(job)) {
        await _finish(job, '${job.srcLang}-ai', SrtParser.format(out),
            SubtitleStore.sha256Of(job.srcSrt));
      }
    } finally {
      await job.mt.dispose();
    }
  }

  /// Carga SEQUENCIAL obrigatória: STT.dispose() antes de MT.load().
  Future<void> _runTranscribe(_Job job) async {
    final tmp =
        job.tmpDirForTest ?? await Directory.systemTemp.createTemp('stt');
    final videoPath = '${tmp.path}/ep${job.ep}.mp4';
    final pcmPath = '${tmp.path}/ep${job.ep}.pcm';
    final stt = job.sttFor!();
    // tiny traduz ja→en (MT recebe 'en'); base/small transcrevem ja (NLLB).
    final mtSrc = stt.id == 'whisper-tiny-ja' ? 'en' : 'ja';
    try {
      final download = job.download ??
          (String url, Map<String, String> h, String out) =>
              ModelManager.fetchFile(
                  dest: File(out), url: url, headers: h,
                  onProgress: (got, total) {
                    final p = total <= 0 ? 0.0 : got / total;
                    _set(
                        JobPhase.downloadingVideo, p * 0.25, 'Baixando vídeo…',
                        detail: total <= 0
                            ? '${(got / 1048576).toStringAsFixed(0)} MB'
                            : '${(got / 1048576).toStringAsFixed(0)}/${(total / 1048576).toStringAsFixed(0)} MB');
                  });
      _set(JobPhase.downloadingVideo, 0, 'Baixando vídeo…',
          detail: 'preparando…');
      await download(job.videoUrl, job.headers, videoPath);
      if (_checkCancel(job)) return;
      _set(JobPhase.extractingAudio, 0.26, 'Extraindo áudio…',
          detail: 'convertendo p/ 16 kHz');
      final extract = job.extract ??
          (String url, Map<String, String> h, String out) =>
              AudioExtract.extractPcm16k(
                  path: videoPath, headers: const {}, outPath: out);
      await extract(job.videoUrl, job.headers, pcmPath);
      if (_checkCancel(job)) return;
      _set(JobPhase.loadingVoice, 0.3, 'Carregando modelo de voz…',
          detail: 'pode demorar ~1 min na 1ª vez');
      await stt.load();
      List<SrtCue> srcCues = [];
      try {
        srcCues = await stt.transcribe(pcmPath, onProgress: (p) {
          _set(JobPhase.transcribing, 0.3 + 0.42 * p, 'Transcrevendo áudio…',
              detail: '${(p * 100).toInt()}% do áudio');
        });
      } finally {
        await stt.dispose(); // NUNCA ambos residentes
      }
      if (_checkCancel(job)) return;
      _set(JobPhase.loadingMt, 0.73, 'Carregando tradução…',
          detail: 'voz liberada da memória');
      final mt = job.mt;
      await mt.load();
      try {
        final out = <SrtCue>[];
        for (var i = 0; i < srcCues.length; i++) {
          if (_checkCancel(job)) return;
          out.add(srcCues[i].withText(
              await mt.translate(srcCues[i].text, src: mtSrc, tgt: 'pt')));
          final p = (i + 1) / (srcCues.isEmpty ? 1 : srcCues.length);
          _set(JobPhase.translating, 0.73 + 0.24 * p, 'Traduzindo…',
              detail: srcCues.isEmpty ? '' : '${i + 1}/${srcCues.length} falas');
        }
        await _finish(job, 'ja-ai', SrtParser.format(out),
            SubtitleStore.sha256Of(job.videoUrl));
      } finally {
        await mt.dispose();
      }
    } finally {
      for (final p in [videoPath, pcmPath]) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
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
  final Future<File> Function(
      String url, Map<String, String> headers, String outPath)? download;
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
        download = null,
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
    this.download,
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
