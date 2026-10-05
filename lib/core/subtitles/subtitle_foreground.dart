import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'subtitle_job_manager.dart';

/// Ponte com o serviço Android de primeiro plano (`dataSync`) que mantém o
/// processo vivo e a CPU acordada enquanto um job de legenda roda — o usuário
/// pode sair do app, bloquear a tela ou deslizar o app dos recentes sem matar
/// a geração (o isolate Dart vive na engine cacheada de GoAnimeApp.kt).
///
/// Toda chamada é best-effort: fora do Android (teste/host) ou sem o plugin,
/// o job segue normalmente sem notificação — a ponte NUNCA derruba o job.
///
/// Fluxo:
/// - 1ª fase de trabalho → `start` (startForegroundService + notificação)
/// - fases seguintes → `update` (throttle: troca de fase sempre; só-% no máx.
///   1x/s, pois o loop de tradução dispara por cue)
/// - estado terminal (done/failed/cancelled) → `finish`: notificação final
///   não-ongoing no shade + serviço para (prioridade volta ao normal)
/// - botão "Cancelar" da notificação → Kotlin invoca `cancelRequested` aqui →
///   `SubtitleJobManager.cancelCurrent()` (mesma política do botão da tela).
class SubtitleForeground {
  SubtitleForeground._();

  static const MethodChannel _ch = MethodChannel('goanime_tv/sub_service');
  static bool _inited = false;
  static bool _serviceUp = false;
  static String? _lastSignature;
  static DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// Dono atual da notificação: `true` quando o job ativo é remoto (LegendAI).
  /// Serve para rotear o botão "Cancelar" da notificação ao manager certo.
  static bool _remote = false;

  /// Cancelamento de job remoto (registrado pelo LegendAiQueueSync).
  static Future<void> Function()? remoteCancelHandler;

  static void _initOnce() {
    if (_inited || !Platform.isAndroid) return;
    _inited = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'cancelRequested') {
        final handler = _remote ? remoteCancelHandler : null;
        if (handler != null) {
          unawaited(handler());
        } else {
          SubtitleJobManager.instance.cancelCurrent();
        }
      }
      return null;
    });
  }

  /// Chamado a cada troca de fase (local pelo [SubtitleJobManager], remoto
  /// pelo `LegendAiQueueSync`). `remote` roteia o cancelamento da notificação.
  static void notify(JobState st, {bool remote = false}) {
    if (!Platform.isAndroid) return;
    _initOnce();
    _remote = remote;
    switch (st.phase) {
      case JobPhase.idle:
        return;
      case JobPhase.done:
      case JobPhase.failed:
      case JobPhase.cancelled:
        _serviceUp = false;
        _lastSignature = null;
        unawaited(_send('finish', {
          'message': switch (st.phase) {
            JobPhase.done =>
              st.message.isEmpty ? 'Legenda pronta' : st.message,
            JobPhase.cancelled => 'Geração cancelada',
            _ => 'Falhou — abra o app para ver o motivo',
          },
          'detail': st.phase == JobPhase.failed
              ? (st.error ?? '').split('\n').first
              : '',
          'success': st.phase == JobPhase.done,
        }));
        return;
      default:
        final sig =
            '${st.phase.name}|${(st.progress * 100).round()}|${st.detail}';
        final now = DateTime.now();
        final phaseChanged =
            sig.split('|').first != _lastSignature?.split('|').first;
        if (!phaseChanged && sig == _lastSignature) return;
        if (!phaseChanged &&
            now.difference(_lastPush) < const Duration(seconds: 1)) {
          return;
        }
        _lastSignature = sig;
        _lastPush = now;
        final method = _serviceUp ? 'update' : 'start';
        _serviceUp = true;
        unawaited(_send(method, {
          'message': st.message.isEmpty
              ? (_remote ? 'Gerando legenda no PC…' : 'Gerando legenda…')
              : st.message,
          'detail': st.detail,
          'progress': st.progress,
        }));
    }
  }

  static Future<void> _send(String method, Map<String, Object?> args) async {
    try {
      await _ch.invokeMethod(method, args);
    } on PlatformException {
      // FGS recusado (ex.: restrição de start em 2º plano) — segue sem.
    } on MissingPluginException {
      // Host de teste/desktop.
    } catch (_) {
      // Nunca derrubar o job por causa da notificação.
    }
  }
}
