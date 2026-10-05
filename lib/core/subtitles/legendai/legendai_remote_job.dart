import 'legendai_client.dart';
import 'legendai_protocol.dart';
import '../subtitle_job_manager.dart' show JobPhase, JobState;

/// Espelho local de um job remoto no LegendAI.
///
/// O PC é a fonte de verdade; este modelo existe para a UI mostrar progresso,
/// persistir entre aberturas do app e marcar o que já foi baixado localmente.
class RemoteJob {
  final String jobId;
  final String? clientJobId;
  final String animeKey;
  final int episode;
  LegendAiState state;
  LegendAiStep? step;
  int pct;
  String? detail;
  LegendAiErrorDetail? error;
  LegendAiJobSummary? summary;

  /// SRT já baixado para o `SubtitleStore` (evita re-download).
  bool downloaded;

  /// Tag do `SubtitleStore` onde o SRT caiu (`ja-ai`/`en-ai`/`es-ai`).
  String tag;

  /// Hash da fonte para invalidar cache quando a URL muda.
  String srcHash;

  final int createdMs;
  int updatedMs;

  RemoteJob({
    required this.jobId,
    this.clientJobId,
    required this.animeKey,
    required this.episode,
    required this.state,
    this.step,
    this.pct = 0,
    this.detail,
    this.error,
    this.summary,
    this.downloaded = false,
    this.tag = 'ja-ai',
    this.srcHash = '',
    this.createdMs = 0,
    this.updatedMs = 0,
  });

  factory RemoteJob.fromJob(
    LegendAiJob job, {
    String tag = 'ja-ai',
    String srcHash = '',
  }) => RemoteJob(
    jobId: job.jobId,
    clientJobId: job.clientJobId,
    animeKey: job.animeKey ?? '',
    episode: job.episode ?? 0,
    state: job.state,
    step: job.step,
    pct: job.pct,
    detail: job.detail,
    error: job.error,
    summary: job.summary,
    tag: tag,
    srcHash: srcHash,
    createdMs: job.createdMs,
    updatedMs: job.updatedMs,
  );

  factory RemoteJob.fromJson(Map<String, dynamic> json) => RemoteJob(
    jobId: json['job_id']?.toString() ?? '',
    clientJobId: json['client_job_id']?.toString(),
    animeKey: json['anime_key']?.toString() ?? '',
    episode: (json['episode'] as num?)?.toInt() ?? 0,
    state: legendAiStateFrom(json['state']?.toString()),
    step: legendAiStepFrom(json['step']?.toString()),
    pct: ((json['pct'] as num?)?.toInt() ?? 0).clamp(0, 100),
    detail: json['detail']?.toString(),
    error: json['error'] is Map
        ? LegendAiErrorDetail.fromJson(
            (json['error'] as Map).cast<String, dynamic>(),
          )
        : null,
    summary: json['summary'] is Map
        ? LegendAiJobSummary.fromJson(
            (json['summary'] as Map).cast<String, dynamic>(),
          )
        : null,
    downloaded: json['downloaded'] == true,
    tag: json['tag']?.toString() ?? 'ja-ai',
    srcHash: json['src_hash']?.toString() ?? '',
    createdMs: (json['created_ms'] as num?)?.toInt() ?? 0,
    updatedMs: (json['updated_ms'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'job_id': jobId,
    if (clientJobId != null) 'client_job_id': clientJobId,
    'anime_key': animeKey,
    'episode': episode,
    'state': legendAiStateName(state),
    if (step != null) 'step': step!.name,
    'pct': pct,
    if (detail != null) 'detail': detail,
    if (error != null) 'error': error!.toJson(),
    if (summary != null) 'summary': summary!.toJson(),
    'downloaded': downloaded,
    'tag': tag,
    'src_hash': srcHash,
    'created_ms': createdMs,
    'updated_ms': updatedMs,
  };

  bool get isActive => switch (state) {
    LegendAiState.pending || LegendAiState.running => true,
    _ => false,
  };

  bool get isDone => state == LegendAiState.done;

  /// Atualiza os campos voláteis a partir do item do servidor, preservando o
  /// que é local (`downloaded`, `tag`, `srcHash`).
  void merge(LegendAiJob job) {
    state = job.state;
    step = job.step;
    pct = job.pct;
    detail = job.detail;
    error = job.error;
    summary = job.summary ?? summary;
    updatedMs = job.updatedMs;
  }

  /// Mapeia o item remoto para o `JobState` que a UI (já existente) consome —
  /// mapeamento etapa→fase do plano §8.5.
  JobState toDisplayState() {
    final detail = this.detail ?? '';
    switch (state) {
      case LegendAiState.done:
        final segs = summary?.segments ?? 0;
        return JobState(
          phase: JobPhase.done,
          progress: 1,
          message: segs > 0
              ? 'Legenda pronta no PC (+$segs falas)'
              : 'Legenda pronta no PC',
        );
      case LegendAiState.error:
        final e = error;
        return JobState(
          phase: JobPhase.failed,
          progress: pct / 100,
          message: 'Falhou no PC',
          error: e == null
              ? 'O PC não informou o erro.'
              : friendlyLegendAiError(
                  LegendAiException(e.code, e.message, hint: e.hint),
                ),
        );
      case LegendAiState.cancelled:
        return const JobState(phase: JobPhase.cancelled, message: 'Cancelado');
      case LegendAiState.pending:
        return const JobState(
          phase: JobPhase.idle,
          message: 'Na fila do PC…',
          detail: 'aguardando um worker',
        );
      case LegendAiState.running:
        return _runningState(detail);
      case LegendAiState.unknown:
        return JobState(
          phase: JobPhase.failed,
          progress: pct / 100,
          message: 'Falhou no PC',
          error: 'O PC devolveu um estado desconhecido. Atualize o app.',
        );
    }
  }

  JobState _runningState(String detail) {
    final msgPrefix = detail.isEmpty ? '' : ' · $detail';
    switch (step) {
      case LegendAiStep.extract:
        return JobState(
          phase: JobPhase.downloadingVideo,
          progress: pct / 100,
          message: 'Baixando e extraindo no PC…',
          detail: '$pct%$msgPrefix',
        );
      case LegendAiStep.transcribe:
        return JobState(
          phase: JobPhase.transcribing,
          progress: pct / 100,
          message: 'Transcrevendo no PC…',
          detail: '$pct% do áudio',
        );
      case LegendAiStep.translate:
        return JobState(
          phase: JobPhase.translating,
          progress: pct / 100,
          message: 'Traduzindo no PC…',
          detail: '$pct%$msgPrefix',
        );
      case LegendAiStep.format:
      case LegendAiStep.export:
        return JobState(
          phase: JobPhase.saving,
          progress: pct / 100,
          message: 'Salvando no PC…',
        );
      case LegendAiStep.done:
        return JobState(
          phase: JobPhase.saving,
          progress: 0.99,
          message: 'Finalizando no PC…',
        );
      case LegendAiStep.unknown:
      case null:
        return JobState(
          phase: JobPhase.transcribing,
          progress: pct / 100,
          message: 'Processando no PC…',
          detail: '${pct % 100}%',
        );
    }
  }
}
