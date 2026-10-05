import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/legendai/legendai_connection.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

MockClient _server() => MockClient((req) async {
  if (req.url.path == '/v1/info') {
    return _json({
      'name': 'PC-Jabs',
      'host': '192.168.2.109',
      'port': 8765,
      'protocol': 1,
      'version': '0.2.0',
      'url': 'http://192.168.2.109:8765',
    });
  }
  if (req.url.path == '/v1/health') {
    return _json({
      'app': 'legendai',
      'version': '0.2.0',
      'protocol': 1,
      'name': 'PC-Jabs',
      'tier': 'Tier2',
      'gpu': true,
      'busy': 0,
      'queue': 0,
      'models': {'stt': 'a', 'translation': 'b'},
    });
  }
  return http.Response('not found', 404);
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorage.init();
    await SettingsService.instance.init();
    LegendAiConnection.instance.debugUseClient(null);
    await LegendAiConnection.instance.disconnect();
  });

  tearDown(() {
    LegendAiConnection.instance.debugUseClient(null);
  });

  test('sem pareamento: baseUri/client nulos e status unconfigured', () {
    final c = LegendAiConnection.instance;
    expect(c.isConfigured, isFalse);
    expect(c.baseUri, isNull);
    expect(c.client, isNull);
    expect(c.status.value, LegendAiStatus.unconfigured);
  });

  test('test() online preenche health/info e healthLabel', () async {
    final c = LegendAiConnection.instance;
    c.debugUseClient(_server());
    final ok = await c.test(host: '192.168.2.109', port: 8765);
    expect(ok, isTrue);
    expect(c.status.value, LegendAiStatus.online);
    expect(c.health!.name, 'PC-Jabs');
    expect(c.healthLabel, contains('PC-Jabs'));
    expect(c.healthLabel, contains('Tier2'));
    expect(c.healthLabel, contains('GPU'));
  });

  test('test() offline quando o PC não responde', () async {
    final c = LegendAiConnection.instance;
    c.debugUseClient(MockClient((_) async => http.Response('erro', 500)));
    final ok = await c.test(host: '10.0.0.9', port: 8765);
    expect(ok, isFalse);
    expect(c.status.value, LegendAiStatus.offline);
    expect(c.health, isNull);
  });

  test('saveAndConnect persiste e sobrevive a novo init', () async {
    final c = LegendAiConnection.instance;
    c.debugUseClient(_server());
    final ok = await c.saveAndConnect(host: '192.168.2.109', port: 8765);
    expect(ok, isTrue);
    expect(SettingsService.instance.legendAiHost, '192.168.2.109');
    expect(SettingsService.instance.legendAiPort, 8765);
    expect(SettingsService.instance.legendAiConfigured, isTrue);

    // Simula restart: reinit lê do mock de prefs (persistiu).
    await SettingsService.instance.init();
    expect(SettingsService.instance.legendAiHost, '192.168.2.109');
  });

  test('disconnect limpa o endereço', () async {
    final c = LegendAiConnection.instance;
    c.debugUseClient(_server());
    await c.saveAndConnect(host: '192.168.2.109', port: 8765);
    await c.disconnect();
    expect(c.isConfigured, isFalse);
    expect(c.status.value, LegendAiStatus.unconfigured);
    expect(SettingsService.instance.legendAiHost, '');
  });
}
