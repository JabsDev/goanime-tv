import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'legendai_protocol.dart';

/// Erro tipado do cliente LegendAI. `code` é estável (`unreachable`,
/// `timeout`, `protocol_mismatch`, `invalid_request`, ... ou o código do
/// servidor). `hint` vem do servidor quando existe.
class LegendAiException implements Exception {
  final String code;
  final String message;
  final String? hint;
  final int? statusCode;

  const LegendAiException(
    this.code,
    this.message, {
    this.hint,
    this.statusCode,
  });

  /// Endereço inalcançável (PC desligado, IP errado, firewall).
  factory LegendAiException.unreachable([Object? cause]) => LegendAiException(
    'unreachable',
    'Não foi possível alcançar o LegendAI. '
        'Confira se o PC está ligado e o IP está correto.',
    hint: cause?.toString(),
  );

  bool get isConnectionError =>
      code == 'unreachable' || code == 'timeout' || code == 'server_down';

  @override
  String toString() => 'LegendAiException($code): $message';
}

/// Servidor com `protocol` maior do que este app entende.
class LegendAiProtocolException extends LegendAiException {
  final int serverProtocol;
  const LegendAiProtocolException(this.serverProtocol)
    : super(
        'protocol_mismatch',
        'O LegendAI do PC fala um protocolo mais novo '
            '($serverProtocol > $kLegendAiProtocol). Atualize o app.',
      );
}

/// Cliente HTTP do protocolo `/v1`. Injetável (`http.Client`) para os testes.
class LegendAiClient {
  final Uri baseUrl;
  final http.Client _http;
  final Duration timeout;

  LegendAiClient({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _http = client ?? http.Client();

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = baseUrl.path.endsWith('/')
        ? baseUrl.path
        : '${baseUrl.path}/';
    final p = path.startsWith('/') ? path.substring(1) : path;
    final uri = baseUrl.replace(path: '$normalized$p');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  Future<http.Response> _guard(Future<http.Response> Function() send) async {
    try {
      return await send().timeout(timeout);
    } on TimeoutException {
      throw const LegendAiException(
        'timeout',
        'O PC demorou demais para responder.',
      );
    } on SocketException catch (e) {
      throw LegendAiException.unreachable(e);
    } on http.ClientException catch (e) {
      throw LegendAiException.unreachable(e);
    } on HandshakeException catch (e) {
      throw LegendAiException.unreachable(e);
    }
  }

  /// Decodifica um corpo JSON; erro do servidor vira [LegendAiException].
  Map<String, dynamic> _decode(http.Response resp) {
    final json = _tryDecode(resp);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      if (json == null) {
        throw LegendAiException(
          'bad_response',
          'O PC respondeu ${resp.statusCode} sem JSON.',
          statusCode: resp.statusCode,
        );
      }
      return json;
    }
    if (json != null) {
      final err = LegendAiErrorDetail.fromJson(json);
      throw LegendAiException(
        err.code,
        err.message,
        hint: err.hint,
        statusCode: resp.statusCode,
      );
    }
    throw LegendAiException(
      'http_${resp.statusCode}',
      'O PC respondeu com erro ${resp.statusCode}.',
      statusCode: resp.statusCode,
    );
  }

  Map<String, dynamic>? _tryDecode(http.Response resp) {
    if (resp.body.isEmpty) return null;
    try {
      final decoded = jsonDecode(resp.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  void _checkProtocol(int protocol) {
    if (protocol > kLegendAiProtocol) {
      throw LegendAiProtocolException(protocol);
    }
  }

  Future<LegendAiHealth> health() async {
    final resp = await _guard(() => _http.get(_uri('v1/health')));
    final h = LegendAiHealth.fromJson(_decode(resp));
    _checkProtocol(h.protocol);
    return h;
  }

  Future<LegendAiInfo> info() async {
    final resp = await _guard(() => _http.get(_uri('v1/info')));
    final i = LegendAiInfo.fromJson(_decode(resp));
    _checkProtocol(i.protocol);
    return i;
  }

  Future<List<LegendAiJob>> listJobs({int? sinceMs}) async {
    final resp = await _guard(
      () => _http.get(
        _uri('v1/jobs', sinceMs == null ? null : {'since': '$sinceMs'}),
      ),
    );
    final decoded = jsonDecode(resp.body.isEmpty ? '[]' : resp.body);
    if (decoded is! List) {
      throw const LegendAiException(
        'bad_response',
        'O PC não devolveu a lista de jobs.',
      );
    }
    return decoded
        .whereType<Map>()
        .map((m) => LegendAiJob.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<LegendAiJob> createJob(LegendAiJobRequest request) async {
    final resp = await _guard(
      () => _http.post(
        _uri('v1/jobs'),
        headers: const {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode(request.toJson()),
      ),
    );
    return LegendAiJob.fromJson(_decode(resp));
  }

  Future<LegendAiJob> getJob(String jobId) async {
    final resp = await _guard(() => _http.get(_uri('v1/jobs/$jobId')));
    return LegendAiJob.fromJson(_decode(resp));
  }

  /// `/srt`: 200 texto, 202 (JSON do item) ou 409 (JSON do erro).
  Future<LegendAiSrtResult> getSrt(String jobId) async {
    final resp = await _guard(() => _http.get(_uri('v1/jobs/$jobId/srt')));
    if (resp.statusCode == 200) {
      return LegendAiSrtResult(ready: true, srt: resp.body);
    }
    if (resp.statusCode == 202) {
      return LegendAiSrtResult.pending(LegendAiJob.fromJson(_decode(resp)));
    }
    if (resp.statusCode == 409) {
      final json = _tryDecode(resp);
      if (json != null) {
        return LegendAiSrtResult.failed(LegendAiErrorDetail.fromJson(json));
      }
      return const LegendAiSrtResult.failed(
        LegendAiErrorDetail(code: 'job_failed', message: 'O job falhou no PC.'),
      );
    }
    // Outros erros (404/500) viram exceção — o chamador decide se reenvia.
    _decode(resp);
    return const LegendAiSrtResult(ready: false);
  }

  Future<void> cancelJob(String jobId) async {
    final resp = await _guard(() => _http.post(_uri('v1/jobs/$jobId/cancel')));
    _decode(resp);
  }

  Future<void> deleteJob(String jobId) async {
    final resp = await _guard(() => _http.delete(_uri('v1/jobs/$jobId')));
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    _decode(resp);
  }

  /// `POST /v1/uploads` (Fase 5 — fallback de áudio): envia o arquivo como
  /// corpo binário cru. `onProgress` reporta os bytes enviados (para a
  /// notificação de 1º plano). Devolve o `upload_id` para o `POST /v1/jobs`.
  Future<LegendAiUpload> uploadAudio(
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final total = await file.length();
    final request = http.StreamedRequest('POST', _uri('v1/uploads'))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = total;
    var sent = 0;
    unawaited(
      file
          .openRead()
          .forEach((chunk) {
            sent += chunk.length;
            onProgress?.call(sent, total);
            request.sink.add(chunk);
          })
          .then(
            (_) => request.sink.close(),
            onError: (Object e, StackTrace st) =>
                request.sink.addError(e, st),
          ),
    );
    final resp = await _guard(
      () async => http.Response.fromStream(await _http.send(request)),
    );
    return LegendAiUpload.fromJson(_decode(resp));
  }

  void close() => _http.close();
}

/// Erro técnico → frase PT-BR acionável para a UI.
String friendlyLegendAiError(Object error) {
  if (error is LegendAiProtocolException) return error.message;
  if (error is LegendAiException) {
    final code = error.code;
    if (error.isConnectionError) return error.message;
    if (code == 'no_audio_track') {
      return 'O PC não encontrou faixa de áudio nessa fonte. Tente outra.';
    }
    if (code == 'unsupported_stream') {
      return 'O PC não conseguiu abrir essa fonte (DASH/token). '
          'Tente outra qualidade ou gere no aparelho.';
    }
    if (code == 'no_speech') {
      return 'O PC não detectou fala nesse episódio.';
    }
    if (code == 'not_found') {
      return 'O job saiu da fila do PC (reiniciou?). Tente de novo.';
    }
    if (code == 'job_cancelled') return 'Cancelado no PC.';
    final hint = error.hint;
    return hint == null || hint.isEmpty
        ? error.message
        : '${error.message} ($hint)';
  }
  if (error is SocketException) {
    return 'Sem conexão com a rede local. Verifique o Wi-Fi/ethernet.';
  }
  final s = error.toString();
  return 'Falhou no PC: ${s.length > 120 ? '${s.substring(0, 120)}…' : s}';
}
