import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Detecção TV × celular + política de orientação (celular retrato, TV landscape).
/// ponytail: MethodChannel puro + MediaQuery, sem device_info_plus.
class DeviceType {
  @visibleForTesting
  static const channel = MethodChannel('goanime_tv/uimode');

  @visibleForTesting
  static const int uiModeTypeTelevision = 4;

  static bool? _cachedIsTv;

  /// Consulta o UiModeManager. `null` quando o canal não está pronto/falhou
  /// (NÃO é o mesmo que "celular").
  static Future<bool?> _query() async {
    try {
      final mode = await channel.invokeMethod<int>('getUiModeType');
      return parseUiModeType(mode);
    } catch (e) {
      debugPrint('[DeviceType] uimode detect failed: $e');
      return null;
    }
  }

  /// True em Android TV (UiModeManager UI_MODE_TYPE_TELEVISION). Fallback false.
  ///
  /// Só memoiza uma resposta VÁLIDA: uma falha (canal indisponível numa corrida
  /// de boot) não pode envenenar o cache para o resto da sessão — a próxima
  /// chamada tenta de novo e a TV volta a ser reconhecida.
  static Future<bool> isTelevision() async {
    if (_cachedIsTv != null) return _cachedIsTv!;
    final result = await _query();
    if (result != null) _cachedIsTv = result;
    return result ?? false;
  }

  /// Parse puro/testável: 4 (TELEVISION) → true, resto/null → false.
  @visibleForTesting
  static bool parseUiModeType(int? mode) =>
      mode == uiModeTypeTelevision;

  /// Política pura/testável: TV → landscape; celular → retrato travado.
  static List<DeviceOrientation> orientationsFor(bool isTv) => isTv
      ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
      : const [DeviceOrientation.portraitUp];

  /// Aplica no boot (chamar após ensureInitialized, antes do runApp).
  ///
  /// Reintenta algumas vezes: o `main()` roda no onCreate do processo (engine
  /// cacheada), então o canal nativo pode não estar pronto no primeiríssimo
  /// instante. Se TODAS as tentativas falharem, NÃO trava retrato — deixar a
  /// orientação livre evita o sintoma "TV esticada" num aparelho que só não
  /// respondeu o modo. Televisão detectada trava landscape normalmente.
  static Future<void> applyStartupPolicy() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final result = await _query();
      if (result != null) {
        _cachedIsTv = result;
        await SystemChrome.setPreferredOrientations(orientationsFor(result));
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    debugPrint('[DeviceType] uimode indisponível no boot; '
        'deixando orientação livre (sem forçar retrato)');
  }

  /// Player: landscape nos dois form factors (padrão YouTube).
  static Future<void> lockLandscapeForPlayer() =>
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);

  /// Saída do player: restaura a política do boot.
  static Future<void> restoreAfterPlayer() async {
    final isTv = await isTelevision();
    await SystemChrome.setPreferredOrientations(orientationsFor(isTv));
  }

  @visibleForTesting
  static void resetCache() => _cachedIsTv = null;
}
