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
  static const _kAutoSkipIntro = 'settings_auto_skip_intro';
  static const _kSttModel = 'settings_ai_stt'; // 'sensevoice'|'jav03'
  static const _kMtEngine = 'settings_ai_mt'; // 'manga'|'completa'
  // LegendAI (PC) — Fase 3: endereço do servidor na LAN + modo padrão.
  static const _kLegendAiHost = 'settings_legendai_host';
  static const _kLegendAiPort = 'settings_legendai_port';
  static const _kSubtitleSource = 'settings_subtitle_source'; // 'device'|'pc'

  /// Whitelist do setter. Poda Fase 1: só os tiers ALTOS. Inválido → default
  /// ('sensevoice'/'manga'), nunca nos tiers baixos removidos (tiny/leve).
  static const _sttTiers = {'sensevoice', 'jav03'};
  static const _mtTiers = {'manga', 'completa'};

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

  bool _autoSkipIntro = false;
  final ValueNotifier<bool> _autoSkipIntroVN = ValueNotifier<bool>(false);
  ValueListenable<bool> get autoSkipIntroListenable => _autoSkipIntroVN;
  bool get autoSkipIntro => _autoSkipIntro;

  /// Legenda IA: STT 'sensevoice' (Whisper destilado de anime, leve) ou
  /// 'jav03' (Whisper ja-anime v0.3, melhor CER). Inválidos → 'sensevoice'.
  String _sttModel = 'sensevoice';
  final ValueNotifier<String> _sttModelVN = ValueNotifier<String>('sensevoice');
  ValueListenable<String> get sttModelListenable => _sttModelVN;
  String get sttModel => _sttModel;

  /// Legenda IA: MT 'manga' (Hy-MT2 v3 fine-tune de mangá, melhor p/ anime)
  /// ou 'completa' (Hy-MT2 Q4 base). Inválidos → 'manga'.
  String _mtEngine = 'manga';
  final ValueNotifier<String> _mtEngineVN = ValueNotifier<String>('manga');
  ValueListenable<String> get mtEngineListenable => _mtEngineVN;
  String get mtEngine => _mtEngine;

  /// LegendAI (PC): endereço do servidor na LAN. Vazio = não configurado.
  String _legendAiHost = '';
  int _legendAiPort = 8765;
  final ValueNotifier<String> _legendAiAddressVN = ValueNotifier<String>('');
  ValueListenable<String> get legendAiAddressListenable => _legendAiAddressVN;
  String get legendAiHost => _legendAiHost;
  int get legendAiPort => _legendAiPort;
  bool get legendAiConfigured => _legendAiHost.trim().isNotEmpty;

  /// Onde gerar a legenda por padrão: 'device' (aparelho) ou 'pc' (LegendAI).
  String _subtitleSource = 'device';
  final ValueNotifier<String> _subtitleSourceVN = ValueNotifier<String>(
    'device',
  );
  ValueListenable<String> get subtitleSourceListenable => _subtitleSourceVN;
  String get subtitleSource => _subtitleSource;

  /// Auditoria de legenda (RETIRADA do fluxo na Fase 1): 'off' é o único
  /// valor efetivo. Os campos/API seguem existindo apenas para os testes de
  /// integração do recurso (que setam em runtime); o app sempre inicia com
  /// 'off' e o job não executa mais auditoria.
  String _auditKind = 'off';
  final ValueNotifier<String> _auditKindVN = ValueNotifier<String>('off');
  ValueListenable<String> get auditKindListenable => _auditKindVN;
  String get auditKind => _auditKind;

  Future<void> init() async {
    LocalStorage.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    _userPref = prefs.getBool(_kLiteMode);
    _autoLite = await DeviceCapability.isLowEnd();
    _initialized = true;
    _onboardingSeen = prefs.getBool(_kOnboardingSeen) ?? false;
    _liteModeVN.value = _resolveLite();
    _nsfwFilter = NsfwFilterSetting
        .values[prefs.getInt(_kNsfwFilter) ?? NsfwFilterSetting.strict.index];
    _nsfwFilterVN.value = _nsfwFilter;
    _autoSkipIntro = prefs.getBool(_kAutoSkipIntro) ?? false;
    _autoSkipIntroVN.value = _autoSkipIntro;
    // Poda Fase 1: whitelist só dos tiers altos. Preferência persistida fora
    // da lista (tiny/base/small/anime-whisper/minima/anime/leve/lmt) migra
    // para o default novo — nunca volta a um tier removido.
    final stored = prefs.getString(_kSttModel);
    _sttModel = _sttTiers.contains(stored) ? stored! : 'sensevoice';
    _sttModelVN.value = _sttModel;
    final storedMt = prefs.getString(_kMtEngine);
    _mtEngine = _mtTiers.contains(storedMt) ? storedMt! : 'manga';
    _mtEngineVN.value = _mtEngine;
    // LegendAI (PC): endereço salvo + modo padrão. Sem migração necessária —
    // ausência significa "nunca pareado": modo padrão continua 'device'.
    _legendAiHost = (prefs.getString(_kLegendAiHost) ?? '').trim();
    _legendAiPort = prefs.getInt(_kLegendAiPort) ?? 8765;
    _legendAiAddressVN.value = legendAiConfigured
        ? '$_legendAiHost:$_legendAiPort'
        : '';
    _subtitleSource = prefs.getString(_kSubtitleSource) == 'pc'
        ? 'pc'
        : 'device';
    _subtitleSourceVN.value = _subtitleSource;
    // Auditoria saiu do fluxo: o valor persistido é ignorado (sempre 'off').
    _auditKind = 'off';
    _auditKindVN.value = _auditKind;
    debugPrint(
      '[Settings] init user=$_userPref auto=$_autoLite lite=$_liteModeVN.value nsfw=$_nsfwFilter autoSkip=$_autoSkipIntro',
    );
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

  Future<void> setAutoSkipIntro(bool v) async {
    _autoSkipIntro = v;
    _autoSkipIntroVN.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSkipIntro, v);
  }

  Future<void> setSttModel(String v) async {
    _sttModel = _sttTiers.contains(v) ? v : 'sensevoice';
    _sttModelVN.value = _sttModel;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSttModel, _sttModel);
  }

  Future<void> setMtEngine(String v) async {
    _mtEngine = _mtTiers.contains(v) ? v : 'manga';
    _mtEngineVN.value = _mtEngine;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMtEngine, _mtEngine);
  }

  /// Salva o endereço do LegendAI (host pode ser IP ou nome `.local`).
  Future<void> setLegendAiAddress(String host, int port) async {
    _legendAiHost = host.trim();
    _legendAiPort = port;
    _legendAiAddressVN.value = legendAiConfigured
        ? '$_legendAiHost:$_legendAiPort'
        : '';
    final prefs = await SharedPreferences.getInstance();
    if (_legendAiHost.isEmpty) {
      await prefs.remove(_kLegendAiHost);
    } else {
      await prefs.setString(_kLegendAiHost, _legendAiHost);
    }
    await prefs.setInt(_kLegendAiPort, port);
  }

  Future<void> clearLegendAiAddress() async {
    _legendAiHost = '';
    _legendAiPort = 8765;
    _legendAiAddressVN.value = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLegendAiHost);
    await prefs.remove(_kLegendAiPort);
  }

  Future<void> setSubtitleSource(String v) async {
    _subtitleSource = v == 'pc' ? 'pc' : 'device';
    _subtitleSourceVN.value = _subtitleSource;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSubtitleSource, _subtitleSource);
  }

  static const _kAuditKind = 'settings_ai_audit';
  static const auditTiers = {
    'off',
    'ja-seq2seq',
    'heretic-1b-it',
    'qwen3-06b',
    'lfm25-dist',
    'lfm12b-audit',
  };
  Future<void> setAuditKind(String v) async {
    _auditKind = auditTiers.contains(v) ? v : 'off';
    _auditKindVN.value = _auditKind;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAuditKind, _auditKind);
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
