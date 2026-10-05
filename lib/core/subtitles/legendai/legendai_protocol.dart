/// Protocolo HTTP `/v1` do LegendAI (Fase 3 — cliente no app).
///
/// Espelha o contrato documentado no plano e implementado no servidor Rust
/// (`LegendAI/src-tauri/src/net/`). Tempos em ms, `episode` inteiro, idiomas
/// ISO 639-1. Os DTOs são classes simples com `fromJson`/`toJson` — sem codegen,
/// para casar com o resto do app.
library;

/// Versão do protocolo suportada por este app. Um servidor com `protocol`
/// maior é recusado (`LegendAiProtocolException`) — evita falar um contrato
/// que não entendemos.
const int kLegendAiProtocol = 1;

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

double _asDouble(Object? v, [double fallback = 0]) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

String? _asString(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

Map<String, dynamic> _asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const {};

/// Estado de um item da fila. `unknown` é forward-compat: um estado que este
/// app não conhece é tratado como terminal (não fica em polling eterno).
enum LegendAiState { pending, running, done, error, cancelled, unknown }

LegendAiState legendAiStateFrom(String? raw) => switch (raw) {
  'pending' => LegendAiState.pending,
  'running' => LegendAiState.running,
  'done' => LegendAiState.done,
  'error' => LegendAiState.error,
  'cancelled' => LegendAiState.cancelled,
  _ => LegendAiState.unknown,
};

String legendAiStateName(LegendAiState s) => switch (s) {
  LegendAiState.pending => 'pending',
  LegendAiState.running => 'running',
  LegendAiState.done => 'done',
  LegendAiState.error => 'error',
  LegendAiState.cancelled => 'cancelled',
  LegendAiState.unknown => 'unknown',
};

/// Etapa do pipeline no PC (`extract`→`transcribe`→`translate`→`format`→`export`).
enum LegendAiStep {
  extract,
  transcribe,
  translate,
  format,
  export,
  done,
  unknown,
}

LegendAiStep? legendAiStepFrom(String? raw) => switch (raw) {
  'extract' => LegendAiStep.extract,
  'transcribe' => LegendAiStep.transcribe,
  'translate' => LegendAiStep.translate,
  'format' => LegendAiStep.format,
  'export' => LegendAiStep.export,
  'done' => LegendAiStep.done,
  null => null,
  _ => LegendAiStep.unknown,
};

/// `{ code, message, hint }` — erro estável do servidor (nunca cruza stack).
class LegendAiErrorDetail {
  final String code;
  final String message;
  final String? hint;

  const LegendAiErrorDetail({
    required this.code,
    required this.message,
    this.hint,
  });

  factory LegendAiErrorDetail.fromJson(Map<String, dynamic> json) =>
      LegendAiErrorDetail(
        code: _asString(json['code']) ?? 'unknown',
        message: _asString(json['message']) ?? 'O PC não informou o erro.',
        hint: _asString(json['hint']),
      );

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (hint != null) 'hint': hint,
  };

  @override
  String toString() => 'LegendAiErrorDetail($code: $message)';
}

/// Modelos ativos no PC (`/health` e `/models`).
class LegendAiModels {
  final String stt;
  final String translation;

  const LegendAiModels({required this.stt, required this.translation});

  factory LegendAiModels.fromJson(Map<String, dynamic> json) => LegendAiModels(
    stt: _asString(json['stt']) ?? '',
    translation: _asString(json['translation']) ?? '',
  );

  Map<String, dynamic> toJson() => {'stt': stt, 'translation': translation};
}

/// `GET /v1/health`.
class LegendAiHealth {
  final String app;
  final String version;
  final int protocol;
  final String name;
  final String tier;
  final bool gpu;
  final int busy;
  final int queue;
  final LegendAiModels models;

  const LegendAiHealth({
    required this.app,
    required this.version,
    required this.protocol,
    required this.name,
    required this.tier,
    required this.gpu,
    required this.busy,
    required this.queue,
    required this.models,
  });

  factory LegendAiHealth.fromJson(Map<String, dynamic> json) => LegendAiHealth(
    app: _asString(json['app']) ?? 'legendai',
    version: _asString(json['version']) ?? '',
    protocol: _asInt(json['protocol']),
    name: _asString(json['name']) ?? '',
    tier: _asString(json['tier']) ?? '',
    gpu: json['gpu'] == true,
    busy: _asInt(json['busy']),
    queue: _asInt(json['queue']),
    models: LegendAiModels.fromJson(_asMap(json['models'])),
  );

  Map<String, dynamic> toJson() => {
    'app': app,
    'version': version,
    'protocol': protocol,
    'name': name,
    'tier': tier,
    'gpu': gpu,
    'busy': busy,
    'queue': queue,
    'models': models.toJson(),
  };
}

/// `GET /v1/info` — dados de pareamento.
class LegendAiInfo {
  final String name;
  final String host;
  final int port;
  final int protocol;
  final String version;
  final String url;

  const LegendAiInfo({
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
    required this.version,
    required this.url,
  });

  factory LegendAiInfo.fromJson(Map<String, dynamic> json) => LegendAiInfo(
    name: _asString(json['name']) ?? '',
    host: _asString(json['host']) ?? '',
    port: _asInt(json['port']),
    protocol: _asInt(json['protocol']),
    version: _asString(json['version']) ?? '',
    url: _asString(json['url']) ?? '',
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'protocol': protocol,
    'version': version,
    'url': url,
  };
}

/// `summary` de um job concluído.
class LegendAiJobSummary {
  final double durationSecs;
  final int segments;
  final String sourceLang;
  final String targetLang;
  final int srtBytes;
  final int? etaSecs;

  const LegendAiJobSummary({
    required this.durationSecs,
    required this.segments,
    required this.sourceLang,
    required this.targetLang,
    required this.srtBytes,
    this.etaSecs,
  });

  factory LegendAiJobSummary.fromJson(Map<String, dynamic> json) =>
      LegendAiJobSummary(
        durationSecs: _asDouble(json['duration_secs']),
        segments: _asInt(json['segments']),
        sourceLang: _asString(json['source_lang']) ?? '',
        targetLang: _asString(json['target_lang']) ?? '',
        srtBytes: _asInt(json['srt_bytes']),
        etaSecs: json['eta_secs'] == null ? null : _asInt(json['eta_secs']),
      );

  Map<String, dynamic> toJson() => {
    'duration_secs': durationSecs,
    'segments': segments,
    'source_lang': sourceLang,
    'target_lang': targetLang,
    'srt_bytes': srtBytes,
    if (etaSecs != null) 'eta_secs': etaSecs,
  };
}

/// Item da fila como o app vê (`GET /v1/jobs`, `POST /v1/jobs`).
class LegendAiJob {
  final String jobId;
  final String? clientJobId;
  final String? animeKey;
  final int? episode;
  final LegendAiState state;
  final LegendAiStep? step;
  final int pct;
  final String? detail;
  final LegendAiJobSummary? summary;
  final LegendAiErrorDetail? error;
  final String origin;
  final int createdMs;
  final int updatedMs;

  const LegendAiJob({
    required this.jobId,
    this.clientJobId,
    this.animeKey,
    this.episode,
    required this.state,
    this.step,
    this.pct = 0,
    this.detail,
    this.summary,
    this.error,
    this.origin = 'remote',
    this.createdMs = 0,
    this.updatedMs = 0,
  });

  factory LegendAiJob.fromJson(Map<String, dynamic> json) => LegendAiJob(
    jobId: _asString(json['job_id']) ?? '',
    clientJobId: _asString(json['client_job_id']),
    animeKey: _asString(json['anime_key']),
    episode: json['episode'] == null ? null : _asInt(json['episode']),
    state: legendAiStateFrom(json['state'] as String?),
    step: legendAiStepFrom(json['step'] as String?),
    pct: _asInt(json['pct']).clamp(0, 100),
    detail: _asString(json['detail']),
    summary: json['summary'] == null
        ? null
        : LegendAiJobSummary.fromJson(_asMap(json['summary'])),
    error: json['error'] == null
        ? null
        : LegendAiErrorDetail.fromJson(_asMap(json['error'])),
    origin: _asString(json['origin']) ?? 'remote',
    createdMs: _asInt(json['created_ms']),
    updatedMs: _asInt(json['updated_ms']),
  );

  /// `true` para estados que não mudam mais (não precisam de polling).
  bool get isTerminal => switch (state) {
    LegendAiState.done ||
    LegendAiState.error ||
    LegendAiState.cancelled ||
    LegendAiState.unknown => true,
    _ => false,
  };

  bool get isActive => !isTerminal;

  Map<String, dynamic> toJson() => {
    'job_id': jobId,
    if (clientJobId != null) 'client_job_id': clientJobId,
    if (animeKey != null) 'anime_key': animeKey,
    if (episode != null) 'episode': episode,
    'state': legendAiStateName(state),
    if (step != null) 'step': step!.name,
    'pct': pct,
    if (detail != null) 'detail': detail,
    if (summary != null) 'summary': summary!.toJson(),
    if (error != null) 'error': error!.toJson(),
    'origin': origin,
    'created_ms': createdMs,
    'updated_ms': updatedMs,
  };
}

/// `POST /v1/jobs` — pedido de enfileiramento.
///
/// A origem é escolhida pelos campos: `srt` (Fase 5 — rota S remota: o PC só
/// traduz), `uploadId` (Fase 5 — fallback de áudio já extraído pelo app) ou
/// `url` (Fase 2/3 — o PC baixa e transcreve o stream).
class LegendAiJobRequest {
  final String clientJobId;
  final String? animeKey;
  final int? episode;
  final String url;
  final Map<String, String> headers;

  /// Rota S remota: SRT já pronto (EN/ES) para o PC traduzir.
  final String? srt;

  /// Fallback de upload: id devolvido por `POST /v1/uploads`.
  final String? uploadId;

  /// Demuxer do áudio enviado (`s16le` = PCM cru 16 kHz mono do app).
  final String? uploadFormat;

  final String sourceLang;
  final String targetLang;
  final bool translate;
  final String? preferredStt;
  final String? preferredTranslation;
  final int? priority;

  const LegendAiJobRequest({
    required this.clientJobId,
    this.animeKey,
    this.episode,
    this.url = '',
    this.headers = const {},
    this.srt,
    this.uploadId,
    this.uploadFormat,
    this.sourceLang = 'auto',
    this.targetLang = 'pt',
    this.translate = true,
    this.preferredStt,
    this.preferredTranslation,
    this.priority,
  });

  /// Origem serializada conforme o tipo escolhido.
  Map<String, dynamic> get sourceJson {
    if (srt != null) {
      return {'type': 'srt', 'srt': srt, 'source_lang': sourceLang};
    }
    if (uploadId != null) {
      return {
        'type': 'upload',
        'upload_id': uploadId,
        if (uploadFormat != null) 'format': uploadFormat,
      };
    }
    return {'type': 'url', 'url': url, 'headers': headers};
  }

  Map<String, dynamic> toJson() => {
    'client_job_id': clientJobId,
    if (animeKey != null) 'anime_key': animeKey,
    if (episode != null) 'episode': episode,
    'source': sourceJson,
    'source_lang': sourceLang,
    'target_lang': targetLang,
    'translate': translate,
    if (preferredStt != null) 'preferred_stt': preferredStt,
    if (preferredTranslation != null)
      'preferred_translation': preferredTranslation,
    if (priority != null) 'priority': priority,
  };
}

/// Resposta de `POST /v1/uploads` (Fase 5).
class LegendAiUpload {
  final String uploadId;
  final int bytes;

  const LegendAiUpload({required this.uploadId, this.bytes = 0});

  factory LegendAiUpload.fromJson(Map<String, dynamic> json) => LegendAiUpload(
    uploadId: _asString(json['upload_id']) ?? '',
    bytes: _asInt(json['bytes']),
  );
}

/// Resultado de `GET /v1/jobs/{id}/srt`.
///
/// O servidor responde `200 text/plain` (pronto), `202` com o item (ainda não
/// pronto) ou `409` com o `ErrorDetail` (erro/cancelado). O cliente normaliza
/// os três casos aqui.
class LegendAiSrtResult {
  final bool ready;
  final String? srt;
  final LegendAiJob? pending;
  final LegendAiErrorDetail? error;

  const LegendAiSrtResult({
    required this.ready,
    this.srt,
    this.pending,
    this.error,
  });

  const LegendAiSrtResult.pending(LegendAiJob job)
    : ready = false,
      srt = null,
      pending = job,
      error = null;

  const LegendAiSrtResult.failed(LegendAiErrorDetail e)
    : ready = false,
      srt = null,
      pending = null,
      error = e;
}
