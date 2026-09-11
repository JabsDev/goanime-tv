import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Capacidades de decodificação do aparelho (via canal nativo Android).
///
/// Uso atual: o AnimeFire serve episódios só em AV1; num box sem decoder
/// AV1 o ExoPlayer toca o áudio sobre tela preta. O player consulta
/// [supportsAv1] e mostra um aviso honesto em vez da tela preta.
///
/// Fail-open: qualquer erro/canal ausente (testes, desktop) assume suporte —
/// melhor tentar tocar do que barrar à toa.
class DeviceCodecs {
  DeviceCodecs._();

  static const _channel = MethodChannel('goanime_tv/codecs');

  static bool? _supportsAv1;

  static Future<bool> supportsAv1() async {
    final cached = _supportsAv1;
    if (cached != null) return cached;
    try {
      _supportsAv1 = await _channel.invokeMethod<bool>('supportsAv1') ?? true;
    } catch (_) {
      debugPrint('[DeviceCodecs] canal indisponível — assume AV1 OK');
      _supportsAv1 = true;
    }
    return _supportsAv1!;
  }

  @visibleForTesting
  static void resetCache() => _supportsAv1 = null;
}
