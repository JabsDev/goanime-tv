import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../storage/settings_service.dart';
import 'legendai_client.dart';
import 'legendai_protocol.dart';

/// Estado do vínculo com o LegendAI.
enum LegendAiStatus { unconfigured, checking, online, offline }

/// Endereço salvo, teste de conexão e estado online/offline (ValueNotifier).
///
/// A conexão é stateless de rede: `client` é reconstruído quando o endereço
/// muda. O modo sem fio é LAN HTTP em texto claro (decisão §3.4).
class LegendAiConnection {
  LegendAiConnection._();
  static final LegendAiConnection instance = LegendAiConnection._();

  final ValueNotifier<LegendAiStatus> status = ValueNotifier<LegendAiStatus>(
    LegendAiStatus.unconfigured,
  );

  /// Último `/health` bem-sucedido (nome/tier/GPU/versão/fila).
  LegendAiHealth? health;
  LegendAiInfo? info;

  http.Client? _httpForTest;
  LegendAiClient? _client;
  String? _clientAddress;

  String get host => SettingsService.instance.legendAiHost;
  int get port => SettingsService.instance.legendAiPort;
  bool get isConfigured => SettingsService.instance.legendAiConfigured;

  /// `http://host:porta` ou `null` se nunca pareado.
  Uri? get baseUri {
    if (!isConfigured) return null;
    return Uri(scheme: 'http', host: host, port: port);
  }

  /// Cliente pronto para o endereço salvo (null se não configurado).
  LegendAiClient? get client {
    final uri = baseUri;
    if (uri == null) return null;
    final address = '$host:$port';
    if (_client == null || _clientAddress != address) {
      _client?.close();
      _client = LegendAiClient(baseUrl: uri, client: _httpForTest);
      _clientAddress = address;
    }
    return _client;
  }

  /// Rótulo curto para a UI: "PC-Jabs · Tier2 · GPU".
  String get healthLabel {
    final h = health;
    if (h == null) return '';
    final parts = <String>[if (h.name.isNotEmpty) h.name, h.tier];
    if (h.gpu) parts.add('GPU');
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }

  /// @visibleForTesting injeta um `http.Client` (ex.: `MockClient`).
  @visibleForTesting
  void debugUseClient(http.Client? client) {
    _httpForTest = client;
    _client?.close();
    _client = null;
    _clientAddress = null;
  }

  /// Testa um endereço (informado ou o salvo). Atualiza [status]/[health]/[info].
  Future<bool> test({String? host, int? port}) async {
    final h = (host ?? this.host).trim();
    final p = port ?? this.port;
    if (h.isEmpty) {
      status.value = LegendAiStatus.unconfigured;
      health = null;
      info = null;
      return false;
    }
    status.value = LegendAiStatus.checking;
    final probe = LegendAiClient(
      baseUrl: Uri(scheme: 'http', host: h, port: p),
      client: _httpForTest,
      timeout: const Duration(seconds: 5),
    );
    try {
      final i = await probe.info();
      final hh = await probe.health();
      health = hh;
      info = i;
      status.value = LegendAiStatus.online;
      return true;
    } catch (e) {
      debugPrint('[LegendAiConnection] teste falhou: $e');
      health = null;
      info = null;
      status.value = LegendAiStatus.offline;
      return false;
    } finally {
      if (_httpForTest == null) probe.close();
    }
  }

  /// Revalida o endereço salvo sem mudar a configuração.
  Future<bool> refresh() {
    if (!isConfigured) {
      status.value = LegendAiStatus.unconfigured;
      return Future.value(false);
    }
    return test();
  }

  /// Salva o endereço e confirma a conexão. Retorna `true` se o PC respondeu.
  Future<bool> saveAndConnect({required String host, required int port}) async {
    await SettingsService.instance.setLegendAiAddress(host, port);
    return test(host: host, port: port);
  }

  Future<void> disconnect() async {
    await SettingsService.instance.clearLegendAiAddress();
    _client?.close();
    _client = null;
    _clientAddress = null;
    health = null;
    info = null;
    status.value = LegendAiStatus.unconfigured;
  }
}
