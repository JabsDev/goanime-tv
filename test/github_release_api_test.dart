import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/updater/github_release_api.dart';

/// Regressão do bug que travava toda atualização do app.
///
/// O GitHub, depois de promover `v1.5.5+1000083` de pre-release para
/// release, continuou servindo `GET /releases/latest` = **v1.4.7+1000073**
/// (quatro versões atrás). O updaker confiava cegamente nesse caminho
/// rápido: recebia algo instalável e retornava, nunca olhando
/// `/releases?per_page=20`, onde a 1.5.5 aparecia corretamente em primeiro.
///
/// Agora junta os dois e escolhe pelo maior build number.
void main() {
  /// Corpo JSON de uma release (para envolver em `jsonEncode`).
  Map<String, dynamic> rel(String tag, {bool pre = false, bool apk = true}) => {
        'tag_name': tag,
        'prerelease': pre,
        'draft': false,
        'body': 'notas',
        'assets': apk
            ? [
                {
                  'name': 'goanime-tv-$tag.apk',
                  'browser_download_url': 'https://ex/$tag.apk',
                  'size': 100,
                }
              ]
            : [],
      };

  http.Response one(String tag, {bool pre = false, bool apk = true}) =>
      http.Response(jsonEncode(rel(tag, pre: pre, apk: apk)), 200);

  http.Response many(List<Map<String, dynamic>> items) =>
      http.Response(jsonEncode(items), 200);

  group('fetchLatestRelease — /latest desatualizado', () {
    test('ignora o /latest velho e devolve a release maior da lista', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          // GitHub servindo a 1.4.7 mesmo com a 1.5.5 já publicada.
          return one('v1.4.7+1000073');
        }
        return many([
            rel('v1.5.5+1000083'),
            rel('v1.5.4+1000082', pre: true),
            rel('v1.4.7+1000073'),
          ]);
      });

      final res = await fetchLatestRelease(client: client);
      expect(res.httpOk, isTrue);
      expect(res.info, isNotNull);
      expect(res.info!.tagName, 'v1.5.5+1000083',
          reason: 'o build mais alto precisa vencer o /latest desatualizado');
    });

    test('escolhe pelo build, não pela ordem da lista', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('v1.5.0+1000078');
        }
        // Lista fora de ordem de propósito: o maior build vem por último.
        return many([
            rel('v1.5.0+1000078'),
            rel('v1.4.9+1000075'),
            rel('v1.5.5+1000083'),
          ]);
      });
      final res = await fetchLatestRelease(client: client);
      expect(res.info!.tagName, 'v1.5.5+1000083');
    });

    test('nunca oferece pre-release nem draft', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('v1.5.5+1000083');
        }
        return many([rel('v1.6.0+1000084', pre: true)]);
      });
      final res = await fetchLatestRelease(client: client);
      expect(res.info!.tagName, 'v1.5.5+1000083');
      // A pre-release mais nova vira "bloqueada" (feedback), não download.
      expect(res.blockedNewer?.tagName, 'v1.6.0+1000084');
    });

    test('tag sem +N não ganha de uma com build', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('v1.5.5+1000083');
        }
        return many([rel('v9.9.9')]);
      });
      final res = await fetchLatestRelease(client: client);
      expect(res.info!.tagName, 'v1.5.5+1000083');
    });

    test('só pré-releases → sem download, mas com feedback', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('v1.6.0+1000084', pre: true);
        }
        return many([rel('v1.5.9+1000083', pre: true)]);
      });
      final res = await fetchLatestRelease(client: client);
      expect(res.info, isNull);
      expect(res.httpOk, isTrue);
      expect(res.blockedNewer, isNotNull);
    });

    test('docs-only (sem .apk) não vira download', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('notas', apk: false);
        }
        return many([rel('v1.4.7+1000073')]);
      });
      final res = await fetchLatestRelease(client: client);
      expect(res.info!.tagName, 'v1.4.7+1000073');
    });

    test('erro de rede não oferece nada e não quebra', () async {
      final client = MockClient((_) async => http.Response('{}', 403));
      final res = await fetchLatestRelease(client: client);
      expect(res.info, isNull);
      expect(res.httpOk, isFalse);
    });
  });

  group('canal beta — inclui pré-releases com APK', () {
    test('pré-release mais nova vira candidata', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('v1.5.5+1000083');
        }
        return many([
          rel('v1.6.0+1000084', pre: true),
          rel('v1.5.5+1000083'),
        ]);
      });
      final res = await fetchLatestRelease(
        client: client,
        includePrerelease: true,
      );
      expect(res.info?.tagName, 'v1.6.0+1000084');
      expect(res.info?.isPrerelease, isTrue);
      expect(res.blockedNewer, isNull);
    });

    test('draft continua fora do canal beta', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('v1.5.5+1000083');
        }
        final draft = rel('v1.7.0+1000085', pre: true);
        draft['draft'] = true;
        return many([draft, rel('v1.5.5+1000083')]);
      });
      final res = await fetchLatestRelease(
        client: client,
        includePrerelease: true,
      );
      expect(res.info?.tagName, 'v1.5.5+1000083');
    });

    test('pré-release sem APK não é instalável nem no beta', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return one('v1.5.5+1000083');
        }
        return many([rel('v1.6.0+1000084', pre: true, apk: false)]);
      });
      final res = await fetchLatestRelease(
        client: client,
        includePrerelease: true,
      );
      expect(res.info?.tagName, 'v1.5.5+1000083');
      expect(res.blockedNewer?.tagName, 'v1.6.0+1000084');
    });
  });
}