import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/updater/github_release_api.dart';
import 'package:goanime_tv/core/updater/update_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String external;
  _FakePathProvider(this.external);
  @override
  Future<String?> getExternalStoragePath() async => external;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> releaseJson(String tag, {bool pre = false}) => {
        'tag_name': tag,
        'name': tag,
        'body': 'changelog',
        'prerelease': pre,
        'draft': false,
        'assets': [
          {
            'name': 'goanime-tv-$tag.apk',
            'size': 42,
            'browser_download_url': 'http://localhost:9999/goanime.apk',
          },
        ],
      };

  Map<String, dynamic> docsOnly(String tag, {bool pre = false}) => {
        'tag_name': tag,
        'name': tag,
        'body': 'changelog',
        'prerelease': pre,
        'draft': false,
        'assets': <Map<String, dynamic>>[],
      };

  http.Response okList(Object body) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('updater_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    UpdateService.instance.debugReset();
    await UpdateService.instance.init(); // carrega throttle/ignorado das prefs
    UpdateService.instance.debugSetInstalled(build: 1000000, version: '1.0.0');
  });

  tearDown(() async {
    UpdateService.clientOverride = null;
    UpdateService.instance.debugReset();
    await tmp.delete(recursive: true);
  });

  test('label: versionName já com +N não duplica o build', () async {
    UpdateService.instance
        .debugSetInstalled(build: 1000001, version: '1.0.1+1000001');
    expect(UpdateService.instance.installedVersionLabel, '1.0.1+1000001');
    UpdateService.instance.debugSetInstalled(build: 1000000, version: '1.0.0');
    expect(UpdateService.instance.installedVersionLabel, '1.0.0+1000000');
  });

  test('manual: release nova → updateAvailable e retorna true', () async {
    UpdateService.clientOverride = MockClient(
        (req) async => okList(releaseJson('v1.0.1+1000001')));
    final r = await UpdateService.instance.check(manual: true);
    expect(r, isTrue);
    expect(UpdateService.instance.state.value, UpdateState.updateAvailable);
    expect(UpdateService.instance.pending?.tagName, 'v1.0.1+1000001');
  });

  test('auto: mesma versão → idle, sem update', () async {
    UpdateService.clientOverride =
        MockClient((req) async => okList(releaseJson('v1.0.0+1000000')));
    final r = await UpdateService.instance.check(manual: false);
    expect(r, isFalse);
    expect(UpdateService.instance.state.value, UpdateState.idle);
  });

  test('auto throttled: checagem recente → no-op (null)', () async {
    await UpdateService.instance.init(); // recarrega prefs com throttle
    SharedPreferences.setMockInitialValues({
      'update_last_check_at': DateTime.now().millisecondsSinceEpoch - 1,
    });
    await UpdateService.instance.init();
    UpdateService.clientOverride = MockClient((req) async => okList(releaseJson('v1.0.1+1000001')));
    final r = await UpdateService.instance.check(manual: false);
    expect(r, isNull);
    expect(UpdateService.instance.state.value, UpdateState.idle);
  });

  test('manual ignora o throttle do mesmo dia', () async {
    await UpdateService.instance.init(); // recarrega prefs com throttle
    SharedPreferences.setMockInitialValues({
      'update_last_check_at': DateTime.now().millisecondsSinceEpoch - 1,
    });
    await UpdateService.instance.init();
    UpdateService.clientOverride = MockClient(
        (req) async => okList(releaseJson('v1.0.1+1000001')));
    final r = await UpdateService.instance.check(manual: true);
    expect(r, isTrue);
  });

  test('throttle só em sucesso: 429 não grava last_check_at', () async {
    UpdateService.clientOverride =
        MockClient((req) async => http.Response('rate limited', 429));
    final r = await UpdateService.instance.check(manual: false);
    expect(r, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('update_last_check_at'), isNull);
  });

  test('throttle gravado em checagem válida (404)', () async {
    UpdateService.clientOverride =
        MockClient((req) async => http.Response('', 404));
    final r = await UpdateService.instance.check(manual: false);
    expect(r, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('update_last_check_at'), isNotNull);
  });

  test('ignorar versão persiste e bloqueia novo prompt', () async {
    UpdateService.clientOverride = MockClient(
        (req) async => okList(releaseJson('v1.0.1+1000001')));
    expect(await UpdateService.instance.check(manual: true), isTrue);
    final release = UpdateService.instance.pending!;
    await UpdateService.instance.ignore(release);
    expect(UpdateService.instance.state.value, UpdateState.idle);

    final r = await UpdateService.instance.check(manual: true);
    expect(r, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update_ignored_tag'), 'v1.0.1+1000001');
  });

  test('guarda de concorrência: check durante estado ativo é no-op', () async {
    UpdateService.clientOverride = MockClient(
        (req) async => okList(releaseJson('v1.0.1+1000001')));
    expect(await UpdateService.instance.check(manual: true), isTrue);
    expect(UpdateService.instance.state.value, UpdateState.updateAvailable);
    final r = await UpdateService.instance.check(manual: true);
    expect(r, isNull);
  });

  test('manual: docs-only mais nova → false + notice de indisponível',
      () async {
    // latest docs-only (v1.0.1) + lista com a antiga instalável (v1.0.0, igual
    // à instalada). Sem o fix, o app responderia "você está na versão mais
    // recente" mesmo desatualizado (sintoma D).
    UpdateService.clientOverride = MockClient((req) async {
      if (req.url.path.endsWith('/releases/latest')) {
        return okList(docsOnly('v1.0.1+1000001'));
      }
      return okList([
        docsOnly('v1.0.1+1000001'), // docs-only, mais nova
        releaseJson('v1.0.0+1000000'), // instalável, igual à instalada
      ]);
    });
    final r = await UpdateService.instance.check(manual: true);
    expect(r, isFalse);
    expect(UpdateService.instance.state.value, UpdateState.idle);
    expect(UpdateService.instance.lastCheckNotice,
        contains('ainda não está disponível para instalação'));
  });

  test('manual: sem update real → false + "versão mais recente"', () async {
    UpdateService.clientOverride = MockClient(
        (req) async => okList(releaseJson('v1.0.0+1000000')));
    final r = await UpdateService.instance.check(manual: true);
    expect(r, isFalse);
    expect(UpdateService.instance.state.value, UpdateState.idle);
    expect(UpdateService.instance.lastCheckNotice,
        contains('Você está na versão mais recente.'));
  });

  test('manual: latest docs-only + prerelease na lista → notice de indisponível',
      () async {
    UpdateService.clientOverride = MockClient((req) async {
      if (req.url.path.endsWith('/releases/latest')) {
        return okList(docsOnly('v1.1.0+1000010'));
      }
      return okList([
        docsOnly('v1.1.0+1000010'), // docs-only mais novo → blocked
        releaseJson('v1.0.1+1000001', pre: true), // prerelease com apk
        releaseJson('v1.0.0+1000000'), // instalável, igual à instalada
      ]);
    });
    final r = await UpdateService.instance.check(manual: true);
    expect(r, isFalse);
    expect(UpdateService.instance.state.value, UpdateState.idle);
    expect(UpdateService.instance.lastCheckNotice,
        contains('ainda não está disponível para instalação'));
  });

  test('download: chega no instalador (sem canal nativo) → error', () async {
    final bytes = utf8.encode('apk-content');
    UpdateService.clientOverride = MockClient((req) async =>
        http.Response.bytes(bytes, 200,
            headers: {'content-length': '${bytes.length}'}));
    await UpdateService.instance.downloadAndInstall(fakeRelease());
    expect(UpdateService.instance.state.value, UpdateState.error);
    expect(UpdateService.instance.errorMessage, contains('instala'));
  });

  test('digest divergente → aborta antes do install (apk removido)', () async {
    final bytes = utf8.encode('apk-content');
    UpdateService.clientOverride = MockClient((req) async =>
        http.Response.bytes(bytes, 200,
            headers: {'content-length': '${bytes.length}'}));
    await UpdateService.instance
        .downloadAndInstall(fakeRelease(digest: 'deadbeef' * 5));
    expect(UpdateService.instance.state.value, UpdateState.error);
    expect(UpdateService.instance.errorMessage, contains('integridade'));

    final updates = await Directory('${tmp.path}/updates').list().toList();
    expect(updates, isEmpty); // arquivo apagado
  });

  test('digest correto → passa do download para o instalador', () async {
    final bytes = utf8.encode('apk-content');
    UpdateService.clientOverride = MockClient((req) async =>
        http.Response.bytes(bytes, 200,
            headers: {'content-length': '${bytes.length}'}));
    final digest = sha1.convert(bytes).toString();
    await UpdateService.instance.downloadAndInstall(fakeRelease(digest: digest));
    // sem canal nativo a instalação não inicia — cai em error (aguardado),
    // mas NÃO por integridade.
    expect(UpdateService.instance.errorMessage,
        isNot(contains('integridade')));
  });
}

ReleaseInfo fakeRelease({String tag = 'v1.0.1+1000001', String? digest}) =>
    ReleaseInfo(
      tagName: tag,
      apkUrl: Uri.parse('http://localhost:9999/goanime.apk'),
      apkSize: 5,
      apkDigest: digest,
    );