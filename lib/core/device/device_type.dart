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

  /// True em Android TV (UiModeManager UI_MODE_TYPE_TELEVISION). Fallback false.
  static Future<bool> isTelevision() async {
    if (_cachedIsTv != null) return _cachedIsTv!;
    try {
      final mode = await channel.invokeMethod<int>('getUiModeType');
      _cachedIsTv = parseUiModeType(mode);
    } catch (e) {
      debugPrint('[DeviceType] uimode detect failed, assuming phone: $e');
      _cachedIsTv = false;
    }
    return _cachedIsTv!;
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
  static Future<void> applyStartupPolicy() async {
    final isTv = await isTelevision();
    await SystemChrome.setPreferredOrientations(orientationsFor(isTv));
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
