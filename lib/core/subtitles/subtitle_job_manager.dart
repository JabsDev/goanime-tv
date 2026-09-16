import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_extract.dart';
import 'hls_audio_only.dart';
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

  JobPhase? _lastSavedPhase;

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
    // Breadcrumb anti-crash: grava a fase no job file (só ao trocar de fase).
    // Se o SO matar o app (OOM), o próximo boot lê e explica em vez de 0% mudo.
    final cur = _current;
    if (cur != null && _lastSavedPhase != phase) {
      _lastSavedPhase = phase;
      cur.save(progress: progressValue, phase: phase.name).ignore();
    }
  }

  /// Dica de crash CONSUMÍVEL: lê o job pendente e apaga os arquivos.
  /// Nada recomeça sozinho — re-tentativa é sempre toque explícito.
  /// Retorna a fase em português ou null se nada pendente.
  static Future<String?> consumeCrashHint({Directory? jobsDirForTest}) async {
    final dir = await _jobsDirStatic(forTest: jobsDirForTest);
    if (!await dir.exists()) return null;
    String? hint;
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.job.json')) continue;
      try {
        if (hint == null) {
          final m = jsonDecode(await e.readAsString()) as Map;
          final phase = m['phase'] as String? ?? '';
          final anime = m['animeKey'] ?? '?';
          final ep = m['ep'] ?? '?';
          if (phase.isNotEmpty && phase != 'idle') {
            hint = 'O app fechou durante ${_phaseLabel(phase)} '
                '($anime EP$ep). Provável falta de memória — '
                'tente o modelo de voz leve (tiny).';
          }
        }
        await e.delete();
      } catch (_) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    return hint;
  }


  static String _phaseLabel(String phase) {
    switch (phase) {
      case 'downloadingVideo':
        return 'o download do vídeo';
      case 'extractingAudio':
        return 'a extração do áudio';
      case 'loadingVoice':
        return 'o carregamento da voz';
      case 'transcribing':
        return 'a transcrição';
      case 'disposingVoice':
        return 'a liberação da voz';
      case 'loadingMt':
        return 'o carregamento da tradução';
      case 'translating':
        return 'a tradução';
      default:
        return 'a geração da legenda';
    }
  }

  /// Erro técnico → frase PT-BR acionável (a tela mostra + botão Tentar).
  static String friendlyError(Object e) {
    final s = e.toString();
    if (e is SocketException) {
      return 'Sem internet. Verifique a rede e tente de novo.';
    }
    if (s.contains('Stream has already been listened')) {
      return 'Falha interna do worker de voz. Atualize o app e tente de novo.';
    }
    if (s.contains('worker STT sem resposta')) {
      return 'Voz demorou demais (aparelho sem memória?). Tente o modelo leve (tiny).';
    }
    if (s.contains('worker STT:')) {
      final short = s.replaceAll(RegExp(r'^.*worker STT:\s*'), '');
      return 'Voz falhou: ${short.length > 120 ? '${short.substring(0, 120)}…' : short}';
    }
    // Conflito de .so nativos (plano-acao-ort-duplicado-v5 §0): dois
    // libonnxruntime.so incompatíveis disputam o pickFirsts; o eleito
    // quebra um dos lados. Mensagem curta, sem stack (ver _run).
    if (s.contains('dlopen') ||
        s.contains('UnsatisfiedLinkError') ||
        s.contains('OrtGetApi')) {
      return 'Falha nas bibliotecas de tradução desta versão. '
          'Atualize o app e tente de novo.';
    }
    // Aparelho 32-bit: libgoanime_llm.so é stub (sem JNI implementado).
    if (s.contains('No implementation found')) {
      return 'Tradução local indisponível neste aparelho. '
          'Use um aparelho 64-bit.';
    }
    // GGUF truncado ("instalado" mas nativo retorna 0) ou sem RAM (ret -1).
    if (s.contains('LLM_CORRUPT')) {
      return 'Modelo de tradução corrompido ou incompleto. '
          'Apague e baixe de novo no Wi-Fi.';
    }
    if (s.contains('LLM_OOM')) {
      return 'Memória insuficiente p/ tradução. '
          'Feche apps e tente de novo (Q3 leve).';
    }
    // Compat: string legada do Kotlin antes dos códigos LLM_*.
    if (s.contains('falha ao carregar')) {
      return 'Modelo de tradução corrompido ou memória insuficiente. '
          'Baixe de novo no Wi-Fi; se persistir, feche apps.';
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

  Future<Directory> _jobsDir({Directory? forTest}) =>
      _jobsDirStatic(forTest: forTest);

  static Future<Directory> _jobsDirStatic({Directory? forTest}) async {
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
    await _dropStale(dir, animeKey, ep, job.file);
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
    Future<File?> Function()? audioOnlyForTest,
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
      audioOnlyForTest: audioOnlyForTest,
      jobsDir: dir,
      subsDirForTest: subsDirForTest,
      tmpDirForTest: tmpDirForTest,
    );
    await job.save();
    await _dropStale(dir, animeKey, ep, job.file);
    _queue.add(job);
    _pump();
  }

  void _pump() {
    if (_current != null || _queue.isEmpty) return;
    _current = _queue.removeAt(0);
    _lastSavedPhase = null;
    _run(_current!);
  }

  Future<void> _run(_Job job) async {
    try {
      if (job.kind == 'transcribe') {
        await _runTranscribe(job);
      } else {
        await _runTranslate(job);
      }
    } catch (e, st) {
      debugPrint('[SubtitleJob] fail: $e\n$st');
      await job.delete(); // falhou: não resume (re-tentativa é manual)
      final msg = friendlyError(e);
      // Erro interno/mapeado já é acionável: sem stack técnico na tela.
      // Rede/outros mantêm stack curta p/ diagnóstico no aparelho.
      final technical = !(msg.startsWith('Falha interna') ||
          msg.startsWith('Falha nas bibliotecas') ||
          msg.startsWith('Tradução local') ||
          msg.startsWith('Modelo de tradução') ||
          msg.startsWith('Memória insuficiente') ||
          msg.startsWith('Voz '));
      final frames =
          st.toString().split('\n').take(4).join('\n');
      _set(JobPhase.failed, progress.value, 'Falhou',
          error: technical ? '$msg\n$frames' : msg);
    } finally {
      _current = null;
      _pump(); // FIFO: próximo da fila
    }
  }

  /// Apaga jobs obsoletos da mesma chave (kill anterior, retry). Sem isto o
  /// banner de crash e o resume ressuscitam fantasmas junto do job novo.
  Future<void> _dropStale(
      Directory dir, String animeKey, int ep, File? keep) async {
    final prefix = '${SubtitleStore.sanitizeKey(animeKey)}_ep$ep.';
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.job.json')) continue;
      if (!e.path.split('/').last.startsWith(prefix)) continue;
      if (keep != null && e.path == keep.path) continue;
      try {
        await e.delete();
      } catch (_) {}
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
  /// Prefere faixa de áudio separada (HLS `bestaudio`, ~15 MB); mp4 único
  /// baixa o vídeo cheio (limitação do HTTP, sem demux parcial confiável).
  Future<void> _runTranscribe(_Job job) async {
    final tmp =
        job.tmpDirForTest ?? await Directory.systemTemp.createTemp('stt');
    final videoPath = '${tmp.path}/ep${job.ep}.mp4';
    final audioOnlyPath = '${tmp.path}/ep${job.ep}.aac';
    final pcmPath = '${tmp.path}/ep${job.ep}.pcm';
    final stt = job.sttFor!();
    // tiny traduz ja→en (MT recebe 'en'); base/small transcrevem ja (NLLB).
    final mtSrc = stt.id == 'whisper-tiny-ja' ? 'en' : 'ja';
    try {
      String mediaPath = videoPath;
      final audioOnly = await _tryAudioOnly(job, audioOnlyPath);
      if (_checkCancel(job)) return;
      if (audioOnly != null) {
        mediaPath = audioOnly.path;
      } else {
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
      }
      _set(JobPhase.extractingAudio, 0.26, 'Extraindo áudio…',
          detail: 'convertendo p/ 16 kHz');
      final extract = job.extract ??
          (String url, Map<String, String> h, String out) =>
              AudioExtract.extractPcm16k(
                  path: mediaPath, headers: const {}, outPath: out);
      // Teto anti-hang em stick fraco (ponytail: timeout em vez de EventChannel).
      await extract(job.videoUrl, job.headers, pcmPath)
          .timeout(const Duration(minutes: 10), onTimeout: () {
        throw StateError(
            'Extração de áudio demorou demais (timeout 10 min). Tente outra fonte.');
      });
      if (_checkCancel(job)) return;
      _set(JobPhase.loadingVoice, 0.3, 'Carregando modelo de voz…',
          detail: 'pode demorar ~1 min na 1ª vez');
      await stt.load().timeout(const Duration(minutes: 3), onTimeout: () {
        throw StateError(
            'Modelo de voz demorou demais (timeout 3 min). Tente o modelo leve (tiny).');
      });
      List<SrtCue> srcCues = [];
      try {
        srcCues = await stt.transcribe(pcmPath, onProgress: (p) {
          _set(JobPhase.transcribing, 0.3 + 0.42 * p, 'Transcrevendo áudio…',
              detail: '${(p * 100).toInt()}% do áudio');
        });
      } finally {
        // Breadcrumb fino: sem isto, morte dentro do free nativo aparece
        // como "transcrição" e é indistinguível de morte transcrevendo.
        await job.save(progress: 0.72, phase: 'disposingVoice');
        await stt.dispose(); // NUNCA ambos residentes
      }
      if (_checkCancel(job)) return;
      _set(JobPhase.loadingMt, 0.73, 'Carregando tradução…',
          detail: 'voz liberada da memória');
      // Respiro p/ o SO reclamar as páginas do STT antes do GGUF de ~1 GB:
      // sem isto o pico STT-residual + MT tomava LMK-kill (app só fechava).
      await Future.delayed(const Duration(seconds: 2));
      final mt = job.mt;
      await mt.load();
      // Breadcrumb fino: crash na 1ª frase antes aparecia como
      // "carregamento" (o _set(translating) só roda após cada frase).
      await job.save(progress: 0.73, phase: 'translating');
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
      for (final p in [videoPath, audioOnlyPath, pcmPath]) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
    }
  }

  /// Tenta a faixa de áudio separada antes do vídeo cheio. Null = indisponível
  /// (mp4 único, sem grupo AUDIO, AES/BYTERANGE ou qualquer erro).
  Future<File?> _tryAudioOnly(_Job job, String outPath) async {
    if (job.audioOnlyForTest != null) return job.audioOnlyForTest!();
    if (!job.videoUrl.toLowerCase().contains('.m3u8')) return null;
    try {
      _set(JobPhase.downloadingVideo, 0, 'Procurando faixa de áudio…',
          detail: 'só-áudio economiza ~90% do download');
      final pl = await HlsAudioOnly.audioPlaylistUri(job.videoUrl,
          headers: job.headers);
      if (pl == null) return null;
      return await HlsAudioOnly.fetch(pl, File(outPath),
          headers: job.headers, onProgress: (got) {
        _set(JobPhase.downloadingVideo, 0.05, 'Baixando áudio…',
            detail: '${(got / 1048576).toStringAsFixed(0)} MB');
      });
    } catch (_) {
      return null;
    }
  }

  void cancelCurrent() {
    _current?.cancelled = true;
    // Interrompe o nativo (extração PCM); o flag cobre download/transcrição.
    // ignore: discarded_futures
    AudioExtract.cancel();
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
  final Future<File?> Function()? audioOnlyForTest;
  final MtProvider mt;
  final Directory jobsDir;
  final Directory? subsDirForTest;
  final Directory? tmpDirForTest;
  File? file;
  bool cancelled = false;
  // Guarda anti-ressurreição: breadcrumb (_set→save) nunca recria um job
  // já concluído/falhado (save async pode terminar depois do delete).
  bool _deleted = false;

  _Job.translate({
    required this.animeKey,
    required this.ep,
    required this.srcSrt,
    required this.srcLang,
    required this.mt,
    required this.jobsDir,
    this.subsDirForTest,
  })  : kind = 'translate',
        videoUrl = '',
        headers = const {},
        sttFor = null,
        download = null,
        extract = null,
        audioOnlyForTest = null,
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
    this.audioOnlyForTest,
    this.subsDirForTest,
    this.tmpDirForTest,
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

  Future<void> save({double? progress, String? phase}) async {
    if (_deleted) return;
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
      'phase': phase ?? '',
    }));
  }

  Future<void> delete() async {
    _deleted = true;
    try {
      await file?.delete();
    } catch (_) {}
  }
}
