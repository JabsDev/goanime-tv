import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/local_storage.dart';
import '../utils/device_capability.dart';
import '../utils/nsfw_filter.dart';

/// Configurações de runtime + alavancas do "modo lite".
/// ponytail: um único Inherited-ish service expõe getters — leitura uma vez
/// por build(). Antes daqui, todo ajuste visual era hardcoded por toda a UI.
class SettingsService {
  static final SettingsService instance = SettingsService._();
  SettingsService._();

  static const _kLiteMode = 'settings_lite_mode';
  static const _kNsfwFilter = 'settings_nsfw_filter';
  static const _kOnboardingSeen = 'settings_onboarding_seen';

  bool? _userPref;
  bool _autoLite = false;
  bool _initialized = false;
  bool _onboardingSeen = false;

  final ValueNotifier<bool> _liteModeVN = ValueNotifier<bool>(false);
  ValueListenable<bool> get liteModeListenable => _liteModeVN;

  NsfwFilterSetting _nsfwFilter = NsfwFilterSetting.strict;
  final ValueNotifier<NsfwFilterSetting> _nsfwFilterVN =
      ValueNotifier<NsfwFilterSetting>(NsfwFilterSetting.strict);
  ValueListenable<NsfwFilterSetting> get nsfwFilterListenable => _nsfwFilterVN;

  Future<void> init() async {
    LocalStorage.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    _userPref = prefs.getBool(_kLiteMode);
    _autoLite = await DeviceCapability.isLowEnd();
    _initialized = true;
    _onboardingSeen = prefs.getBool(_kOnboardingSeen) ?? false;
    _liteModeVN.value = _resolveLite();
    _nsfwFilter = NsfwFilterSetting.values[
        prefs.getInt(_kNsfwFilter) ?? NsfwFilterSetting.strict.index];
    _nsfwFilterVN.value = _nsfwFilter;
    debugPrint(
        '[Settings] init user=$_userPref auto=$_autoLite lite=$_liteModeVN.value nsfw=$_nsfwFilter');
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

  NsfwFilterSetting get nsfwFilterLevel => _nsfwFilter;

  /// Primeira execução ainda não apresentada. Quando `false` e não há perfis,
  /// o app abre o fluxo de boas-vindas (criar perfil local ou continuar como
  /// Visitante).
  bool get onboardingSeen => _onboardingSeen;

  Future<void> markOnboardingSeen() async {
    _onboardingSeen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingSeen, true);
  }

  Future<void> setNsfwFilterLevel(NsfwFilterSetting v) async {
    _nsfwFilter = v;
    _nsfwFilterVN.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kNsfwFilter, v.index);
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