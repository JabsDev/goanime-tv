import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../subtitle_store.dart';
import '../subtitle_foreground.dart';
import '../subtitle_job_manager.dart' show JobPhase, JobState;
import 'legendai_client.dart';
import 'legendai_connection.dart';
import 'legendai_protocol.dart';
import 'legendai_remote_job.dart';

/// Motor de sincronização da fila remota.
///
/// - **PC é a fonte de verdade**: `refresh()` faz `GET /v1/jobs` e funde os
///   itens remotos no espelho local [`jobs`].
/// - **Polling** de 1,5 s enquanto houver item ativo e o app estiver vivo.
/// - **Download**: ao ver um item `done` ainda não baixado, puxa
///   `GET /srt` e grava no [`SubtitleStore`] (tag por rota, `srcHash` da URL).
/// - **Persistência**: o espelho é gravado em `appSupport/legendai_queue.json`
///   para sobreviver a fechar o app.
class LegendAiQueueSync {
  LegendAiQueueSync({
    LegendAiConnection? connection,
    Directory? storeDirForTest,
    Directory? subsDirForTest,
    this.pollInterval = const Duration(milliseconds: 1500),
  }) : connection = connection ?? LegendAiConnection.instance,
       _storeDirForTest = storeDirForTest,
       _subsDirForTest = subsDirForTest;

  final LegendAiConnection connection;
  final Duration pollInterval;
  final Directory? _storeDirForTest;
  final Directory? _subsDirForTest;

  /// Espelho ordenado (mais recente primeiro). Sempre troca de identidade ao
  /// notificar (ValueNotifier<List>).
  final ValueNotifier<List<RemoteJob>> jobs = ValueNotifier<List<RemoteJob>>(
    const [],
  );

  Timer? _poll;
  bool _refreshing = false;
  bool _loaded = false;
  bool _disposed = false;
  bool _foregroundActive = false;
  Future<void>? _persistChain;

  /// Carrega o espelho persistido. Idempotente.
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    await _load();
    // O botão "Cancelar" da notificação do foreground service deve cancelar o
    // job remoto ativo (não o job local do SubtitleJobManager).
    SubtitleForeground.remoteCancelHandler = _cancelActive;
    if (_hasActive) {
      _notifyForeground();
      _schedulePoll();
    }
  }

  bool get _hasActive => jobs.value.any((j) => j.isActive);

  RemoteJob? jobForClientId(String clientJobId) {
    for (final j in jobs.value) {
      if (j.clientJobId == clientJobId) return j;
    }
    return null;
  }

  RemoteJob? jobById(String jobId) {
    for (final j in jobs.value) {
      if (j.jobId == jobId) return j;
    }
    return null;
  }

  /// Job remoto mais relevante para (anime, ep), de qualquer rota (URL, rota S
  /// ou upload). Prefere um item ativo; senão o mais recente do espelho.
  RemoteJob? jobForEpisode(String animeKey, int episode) {
    final prefix = clientJobIdFor(animeKey, episode);
    RemoteJob? fallback;
    for (final j in jobs.value) {
      final cid = j.clientJobId;
      if (cid == null) continue;
      if (cid != prefix && !cid.startsWith('$prefix:')) continue;
      if (j.isActive) return j;
      fallback ??= j;
    }
    return fallback;
  }

  /// Enfileira um episódio no PC. Idempotente (`client_job_id`): reenvio
  /// após queda devolve o item já existente em vez de duplicar.
  Future<RemoteJob?> submit({
    required String animeKey,
    required int episode,
    required String url,
    Map<String, String> headers = const {},
    String sourceLang = 'auto',
    String targetLang = 'pt',
    String tag = 'ja-ai',
    String? srcHash,
    String? preferredStt,
    String? preferredTranslation,
  }) async {
    final client = connection.client;
    if (client == null) return null;
    final clientJobId = clientJobIdFor(animeKey, episode);
    // Já temos espelho? Reenvio idempotente local (PC devolveria o mesmo).
    final existing = jobForClientId(clientJobId);
    if (existing != null && (existing.isActive || existing.isDone)) {
      if (existing.isActive) _schedulePoll();
      return existing;
    }
    final created = await client.createJob(
      LegendAiJobRequest(
        clientJobId: clientJobId,
        animeKey: animeKey,
        episode: episode,
        url: url,
        headers: headers,
        sourceLang: sourceLang,
        targetLang: targetLang,
        translate: true,
        preferredStt: preferredStt,
        preferredTranslation: preferredTranslation,
      ),
    );
    final remote = RemoteJob.fromJob(
      created,
      tag: tag,
      srcHash: srcHash ?? SubtitleStore.sha256Of(url),
    );
    _upsert(remote);
    _schedulePoll();
    unawaited(refresh());
    return remote;
  }

  /// Rota S remota (Fase 5): envia um SRT EN/ES já pronto para o PC traduzir
  /// (o PC pula extração/STT). Idempotente por `client_job_id` com o idioma.
  Future<RemoteJob?> submitSrt({
    required String animeKey,
    required int episode,
    required String srt,
    required String sourceLang,
    String targetLang = 'pt',
    String tag = 'en-ai',
    String? srcHash,
  }) async {
    final client = connection.client;
    if (client == null) return null;
    final clientJobId = clientJobIdFor(
      animeKey,
      episode,
      kind: 'srt-$sourceLang',
    );
    final existing = jobForClientId(clientJobId);
    if (existing != null && (existing.isActive || existing.isDone)) {
      if (existing.isActive) _schedulePoll();
      return existing;
    }
    final created = await client.createJob(
      LegendAiJobRequest(
        clientJobId: clientJobId,
        animeKey: animeKey,
        episode: episode,
        srt: srt,
        sourceLang: sourceLang,
        targetLang: targetLang,
        translate: true,
      ),
    );
    final remote = RemoteJob.fromJob(
      created,
      tag: tag,
      srcHash: srcHash ?? SubtitleStore.sha256Of(srt),
    );
    _upsert(remote);
    _schedulePoll();
    unawaited(refresh());
    return remote;
  }

  /// Fallback de upload (Fase 5): envia o áudio já extraído pelo app (PCM cru
  /// 16 kHz mono) e enfileira no PC. Usado quando o ffmpeg do PC não abre o
  /// stream (DASH/token). Reporta o progresso do envio no 1º plano.
  Future<RemoteJob?> submitUpload({
    required String animeKey,
    required int episode,
    required File audioFile,
    String format = 's16le',
    String sourceLang = 'auto',
    String targetLang = 'pt',
    String tag = 'ja-ai',
    String? srcHash,
  }) async {
    final client = connection.client;
    if (client == null) return null;
    final clientJobId = clientJobIdFor(animeKey, episode, kind: 'upload');
    final existing = jobForClientId(clientJobId);
    if (existing != null && (existing.isActive || existing.isDone)) {
      if (existing.isActive) _schedulePoll();
      return existing;
    }
    SubtitleForeground.notify(
      const JobState(
        phase: JobPhase.downloadingVideo,
        progress: 0,
        message: 'Enviando áudio ao PC…',
      ),
      remote: true,
    );
    final up = await client.uploadAudio(
      audioFile,
      onProgress: (sent, total) {
        final p = total <= 0 ? 0.0 : sent / total;
        SubtitleForeground.notify(
          JobState(
            phase: JobPhase.downloadingVideo,
            progress: p,
            message: 'Enviando áudio ao PC…',
            detail: total <= 0
                ? '${(sent / 1048576).toStringAsFixed(0)} MB'
                : '${(sent / 1048576).toStringAsFixed(0)}/'
                      '${(total / 1048576).toStringAsFixed(0)} MB',
          ),
          remote: true,
        );
      },
    );
    final created = await client.createJob(
      LegendAiJobRequest(
        clientJobId: clientJobId,
        animeKey: animeKey,
        episode: episode,
        uploadId: up.uploadId,
        uploadFormat: format,
        sourceLang: sourceLang,
        targetLang: targetLang,
        translate: true,
      ),
    );
    final remote = RemoteJob.fromJob(
      created,
      tag: tag,
      srcHash: srcHash ?? SubtitleStore.sha256Of('upload:$animeKey:$episode'),
    );
    _upsert(remote);
    _schedulePoll();
    unawaited(refresh());
    return remote;
  }

  /// Reconcilia com o PC e baixa SRTs concluídos.
  Future<void> refresh() async {
    final client = connection.client;
    if (client == null || _refreshing || _disposed) return;
    _refreshing = true;
    try {
      final items = await client.listJobs();
      final remote = items
          .where(
            (i) =>
                i.clientJobId != null && i.clientJobId!.startsWith('goanime:'),
          )
          .toList();
      final byClient = {for (final i in remote) i.clientJobId!: i};
      var changed = false;
      for (final job in jobs.value) {
        final cid = job.clientJobId;
        final item = cid == null ? null : byClient[cid];
        if (item != null) {
          job.merge(item);
          changed = true;
        } else if (job.isActive) {
          // Sumiu do servidor: o LegendAI perdeu a fila (reiniciou sem
          // snapshot). Marca como falha para o usuário poder reenviar.
          job.state = LegendAiState.error;
          job.error = const LegendAiErrorDetail(
            code: 'lost_on_pc',
            message: 'O job saiu da fila do PC (o LegendAI reiniciou?).',
            hint: 'Toque em Tentar de novo para reenviar.',
          );
          changed = true;
        }
      }
      if (changed) _notifyAndPersist();
      // Baixa qualquer concluído ainda não salvo localmente.
      for (final job in List<RemoteJob>.of(jobs.value)) {
        if (job.isDone && !job.downloaded) await _download(job);
      }
      connection.status.value = LegendAiStatus.online;
    } on LegendAiException catch (e) {
      if (e.isConnectionError) connection.status.value = LegendAiStatus.offline;
    } catch (e) {
      debugPrint('[LegendAiQueueSync] refresh falhou: $e');
    } finally {
      _refreshing = false;
      _schedulePoll();
    }
  }

  /// Cancela um job. Em execução usa `/cancel`; ainda na fila usa `DELETE`
  /// (o servidor só cancela itens rodando — o resto é remoção).
  Future<void> cancel(RemoteJob job) async {
    final client = connection.client;
    if (client == null) return;
    try {
      if (job.state == LegendAiState.running) {
        await client.cancelJob(job.jobId);
        job.state = LegendAiState.cancelled;
      } else {
        await client.deleteJob(job.jobId);
        _removeLocal(job.jobId);
      }
      _notifyAndPersist();
      unawaited(refresh());
    } on LegendAiException catch (e) {
      debugPrint('[LegendAiQueueSync] cancel falhou: $e');
      if (e.isConnectionError) connection.status.value = LegendAiStatus.offline;
      rethrow;
    }
  }

  /// Remove um item terminal do espelho (e do PC, best-effort).
  Future<void> remove(RemoteJob job) async {
    final client = connection.client;
    if (client != null) {
      try {
        await client.deleteJob(job.jobId);
      } on LegendAiException catch (e) {
        debugPrint('[LegendAiQueueSync] remove falhou: $e');
      }
    }
    _removeLocal(job.jobId);
    _notifyAndPersist();
  }

  void _removeLocal(String jobId) {
    jobs.value = jobs.value.where((j) => j.jobId != jobId).toList();
  }

  void _upsert(RemoteJob job) {
    final list = List<RemoteJob>.of(jobs.value)
      ..removeWhere((j) => j.jobId == job.jobId)
      ..insert(0, job);
    jobs.value = list;
    _notifyAndPersist();
  }

  Future<void> _download(RemoteJob job) async {
    final client = connection.client;
    if (client == null) return;
    try {
      final result = await client.getSrt(job.jobId);
      if (result.ready && (result.srt?.trim().isNotEmpty ?? false)) {
        await SubtitleStore.put(
          animeKey: job.animeKey,
          ep: job.episode,
          tag: job.tag,
          srt: result.srt!,
          srcHash: job.srcHash,
          subsDirForTest: _subsDirForTest,
        );
        job.downloaded = true;
        job.updatedMs = DateTime.now().millisecondsSinceEpoch;
        _notifyAndPersist();
      } else if (result.error != null) {
        if (result.error!.code == 'job_cancelled') {
          job.state = LegendAiState.cancelled;
        } else {
          job.state = LegendAiState.error;
          job.error = result.error;
        }
        _notifyAndPersist();
      }
    } catch (e) {
      debugPrint('[LegendAiQueueSync] getSrt falhou: $e');
      if (e is LegendAiException && e.isConnectionError) {
        connection.status.value = LegendAiStatus.offline;
      }
    }
  }

  void _notifyAndPersist() {
    if (_disposed) return;
    jobs.value = List<RemoteJob>.unmodifiable(jobs.value);
    _schedulePersist();
    _notifyForeground();
  }

  /// Reflete o job remoto ativo na notificação de 1º plano ("Gerando no PC…").
  ///
  /// No Android isso mantém o processo vivo e a CPU acordada enquanto o PC
  /// trabalha; fora do Android é no-op (o `notify` checa a plataforma). Quando
  /// não há mais item ativo, encerra a notificação com o último estado.
  void _notifyForeground() {
    final active = jobs.value.where((j) => j.isActive).toList();
    if (active.isNotEmpty) {
      _foregroundActive = true;
      var st = active.first.toDisplayState();
      // `pending` mapeia para `idle`, que o SubtitleForeground ignora. Como o
      // PC pode ficar na fila um tempo, anuncia "na fila" mesmo assim para
      // manter o processo vivo até o job começar.
      if (st.phase == JobPhase.idle) {
        st = JobState(
          phase: JobPhase.downloadingVideo,
          progress: 0,
          message: st.message,
          detail: st.detail,
        );
      }
      SubtitleForeground.notify(st, remote: true);
      return;
    }
    if (!_foregroundActive) return;
    _foregroundActive = false;
    final last = jobs.value.isEmpty ? null : jobs.value.first;
    SubtitleForeground.notify(
      last?.toDisplayState() ??
          const JobState(phase: JobPhase.cancelled, message: 'Cancelado'),
      remote: true,
    );
  }

  /// Cancela o job remoto ativo (usado pelo botão da notificação).
  Future<void> _cancelActive() async {
    final active = jobs.value.where((j) => j.isActive).toList();
    if (active.isNotEmpty) await cancel(active.first);
  }

  void _schedulePoll() {
    if (_disposed) return;
    if (_hasActive && connection.isConfigured) {
      _poll ??= Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _poll = null;
  }

  // ── Persistência ────────────────────────────────────────────────────────

  Future<File> _storeFile() async {
    final dir =
        _storeDirForTest ??
        Directory('${(await getApplicationSupportDirectory()).path}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/legendai_queue.json');
  }

  Future<void> _load() async {
    try {
      final file = await _storeFile();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return;
      final loaded = raw
          .whereType<Map>()
          .map((m) => RemoteJob.fromJson(m.cast<String, dynamic>()))
          .toList();
      jobs.value = List<RemoteJob>.unmodifiable(loaded);
    } catch (e) {
      debugPrint('[LegendAiQueueSync] load falhou: $e');
    }
  }

  void _schedulePersist() {
    _persistChain = (_persistChain ?? Future<void>.value()).then(
      (_) => _persist(),
    );
  }

  /// Aguarda a gravação em disco pendente (testes/diagnóstico).
  @visibleForTesting
  Future<void> flush() => _persistChain ?? Future<void>.value();

  Future<void> _persist() async {
    try {
      final file = await _storeFile();
      final data = jobs.value.map((j) => j.toJson()).toList();
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('[LegendAiQueueSync] persist falhou: $e');
    }
  }

  /// `client_job_id` estável e idempotente para (anime, episódio). `kind`
  /// distingue as rotas remotas do mesmo episódio (Fase 5: `srt-en`/`upload`);
  /// `null` mantém o id histórico da rota por URL (compatibilidade).
  static String clientJobIdFor(String animeKey, int episode, {String? kind}) {
    final safe = animeKey.replaceAll(':', '_').trim();
    final base = 'goanime:$safe:$episode';
    return kind == null || kind.isEmpty ? base : '$base:$kind';
  }
}
