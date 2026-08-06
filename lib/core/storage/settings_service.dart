import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/local_storage.dart';
import '../utils/device_capability.dart';

/// Configurações de runtime + alavancas do "modo lite".
/// ponytail: um único Inherited-ish service expõe getters — leitura uma vez
/// por build(). Antes daqui, todo ajuste visual era hardcoded por toda a UI.
class SettingsService {
  static final SettingsService instance = SettingsService._();
  SettingsService._();

  static const _kLiteMode = 'settings_lite_mode';

  bool? _userPref;
  bool _autoLite = false;
  bool _initialized = false;

  final ValueNotifier<bool> _liteModeVN = ValueNotifier<bool>(false);
  ValueListenable<bool> get liteModeListenable => _liteModeVN;

  Future<void> init() async {
    LocalStorage.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    _userPref = prefs.getBool(_kLiteMode);
    _autoLite = await DeviceCapability.isLowEnd();
    _initialized = true;
    _liteModeVN.value = _resolveLite();
    debugPrint(
        '[Settings] init user=$_userPref auto=$_autoLite lite=$_liteModeVN.value');
  }

  bool _resolveLite() {
    if (_userPref != null) return _userPref!;
    return _autoLite;
  }

  bool get liteModeActive => _initialized ? _liteModeVN.value : _resolveLite();
  bool get autoDetectedLowEnd => _autoLite;
  bool? get userPreference => _userPref;

  Future<void> setUserPreference(bool? v) async {
    _userPref = v;
    final prefs = await SharedPreferences.getInstance();
    if (v == null) {
      await prefs.remove(_kLiteMode);
    } else {
      await prefs.setBool(_kLiteMode, v);
    }
    _liteModeVN.value = _resolveLite();
  }

  // Levers. Lê uma vez por build(), não em cada widget aninhado.

  Duration get animDuration =>
      liteModeActive ? Duration.zero : const Duration(milliseconds: 200);

  bool get shadowsEnabled => !liteModeActive;

  double get focusGlowBlur => liteModeActive ? 0 : 18.0;

  /// cacheExtent para ListView.builder. Padrão Flutter ~1500px. Lite baixa.
  double get cacheExtent => liteModeActive ? 200 : 1500;

  /// Em busca, enriquecer cada resultado com AniList detail (=+30 HTTP paralelos).
  /// Lite pula — só mostra metadados das próprias fontes.
  bool get anilistEnrichInSearch => !liteModeActive;

  /// Quantas das 10 `_defaultQueries` disparam no fallback de cold-start AniList.
  /// Lite reduz de 10 pra 3 → cascatada de 4×3 = 12 scrapes no lugar de 40.
  int get startupFallbackQueries => liteModeActive ? 3 : 10;
}