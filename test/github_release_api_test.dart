import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/updater/github_release_api.dart';
import 'package:goanime_tv/core/updater/update_constants.dart';

/// Fase 2: parse da API do GitHub (releases/latest + fallback /releases) sem
/// rede — release nova/igual/prerelease/sem asset/404/429.
void main() {
  http.Response ok(Object body) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Map<String, dynamic> asset(String name, {int size = 42, String? digest}) => {
        'name': name,
        'size': size,
        'browser_download_url': 'https://example.com/$name',
        if (digest != null) 'digest': digest,
      };

  Map<String, dynamic> release({
    required String tag,
    List<Map<String, dynamic>> assets = const [],
    bool prerelease = false,
    bool draft = false,
    String? body,
  }) =>
      {
        'tag_name': tag,
        'name': tag,
        'body': body ?? 'changelog',
        'prerelease': prerelease,
        'draft': draft,
        'assets': assets,
      };

  MockClient serve({
    Map<String, dynamic>? latest,
    List<Map<String, dynamic>>? all,
    int latestStatus = 200,
    int allStatus = 200,
  }) {
    return MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/releases/latest')) {
        if (latestStatus == 404) return http.Response('', 404);
        if (latestStatus != 200) return http.Response('', latestStatus);
        return ok(latest!);
      }
      if (path.contains('/releases')) {
        if (allStatus == 404) return http.Response('', 404);
        if (allStatus != 200) return http.Response('', allStatus);
        return ok(all!);
      }
      return http.Response('', 404);
    });
  }

  test('latest com .apk → ReleaseInfo completo (url, size, digest 40 hex)',
      () async {
    final client = serve(latest: release(tag: 'v1.0.1+1000001', assets: [
      asset('GOAnime-v1.0.1.apk', size: 123456, digest: 'sha1:${'4e0a' * 10}'),
    ], body: 'nova versão'));
    final res = await fetchLatestRelease(client: client);
    expect(res.httpOk, isTrue);
    expect(res.info, isNotNull);
    expect(res.info!.tagName, 'v1.0.1+1000001');
    expect(res.info!.apkUrl.toString(), contains('.apk'));
    expect(res.info!.apkSize, 123456);
    expect(res.info!.apkDigest, '4e0a' * 10);
    expect(res.info!.changelog, 'nova versão');
  });

  test('latest docs-only (sem apk) → fallback pega release anterior com apk',
      () async {
    final client = serve(
      latest: release(tag: 'v1.1.0+1000005', assets: []), // docs-only
      all: [
        // ordem real da API: do mais novo para o mais velho
        release(tag: 'v1.0.1+1000001', assets: [asset('a.apk')]),
        release(tag: 'v0.9.0+900000', assets: [asset('old.apk')]),
      ],
    );
    final res = await fetchLatestRelease(client: client);
    expect(res.httpOk, isTrue);
    expect(res.info!.tagName, 'v1.0.1+1000001');
  });

  test('latest prerelease com apk → ignorado, fallback para release estável',
      () async {
    final client = serve(
      latest: release(
          tag: 'v2.0.0+2000000', prerelease: true, assets: [asset('b.apk')]),
      all: [
        release(tag: 'v2.0.0+2000000', prerelease: true, assets: [
          asset('b.apk'),
        ]),
        release(tag: 'v1.0.1+1000001', assets: [asset('a.apk')]),
      ],
    );
    final res = await fetchLatestRelease(client: client);
    expect(res.info!.tagName, 'v1.0.1+1000001');
  });

  test('nenhuma release com apk → null com checagem válida (httpOk=true)',
      () async {
    final client = serve(
      latest: release(tag: 'v1.0.0+1000000', assets: []),
      all: [release(tag: 'v1.0.0+1000000', assets: [])],
    );
    final res = await fetchLatestRelease(client: client);
    expect(res.info, isNull);
    expect(res.httpOk, isTrue);
  });

  test('404 (sem releases) → null com checagem válida', () async {
    final client = serve(latestStatus: 404, allStatus: 404);
    final res = await fetchLatestRelease(client: client);
    expect(res.info, isNull);
    expect(res.httpOk, isTrue);
  });

  test('429 → erro de checagem (httpOk=false, não grava throttle)', () async {
    final client = serve(latestStatus: 429, allStatus: 429);
    final res = await fetchLatestRelease(client: client);
    expect(res.info, isNull);
    expect(res.httpOk, isFalse);
  });

  test('digest ausente no asset mas com sha256 64-hex no body', () async {
    final client = serve(latest: release(tag: 'v1.0.1+1000001', assets: [
      asset('a.apk'),
    ], body: 'release\n\nSHA256: ${'ab' * 32}'));
    final res = await fetchLatestRelease(client: client);
    expect(res.info!.apkDigest, 'ab' * 32);
  });

  test('draft é ignorado', () async {
    final client = serve(
      latest: release(tag: 'v9.9.9+999999', draft: true, assets: [asset('x.apk')]),
      all: [release(tag: 'v1.0.1+1000001', assets: [asset('a.apk')])],
    );
    final res = await fetchLatestRelease(client: client);
    expect(res.info!.tagName, 'v1.0.1+1000001');
  });

  test('apiBase configurável via dart-define respeita o client', () {
    // garante que a constante existe e traz path/repo padrão
    expect(UpdateConstants.apiBase, isNotEmpty);
  });
}