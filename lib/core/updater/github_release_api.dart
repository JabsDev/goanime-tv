import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'update_constants.dart';

/// Modelo de uma release que o app pode instalar. Instâncias só existem para
/// releases que possuem asset `.apk` e não são `prerelease`/`draft`.
class ReleaseInfo {
  final String tagName;
  final String? versionLabel;
  final String? changelog;
  final Uri? apkUrl;
  final int? apkSize;
  final String? apkDigest;
  final bool isPrerelease;
  final bool isDraft;

  const ReleaseInfo({
    required this.tagName,
    this.versionLabel,
    this.changelog,
    this.apkUrl,
    this.apkSize,
    this.apkDigest,
    this.isPrerelease = false,
    this.isDraft = false,
  });

  /// Parse um objeto de release da API do GitHub. Null se a release não deve
  /// ser considerada (pré/draft) ou não tem asset `.apk`.
  static ReleaseInfo? tryParse(Map<String, dynamic> json) {
    final tagName = json['tag_name'] as String?;
    if (tagName == null || tagName.isEmpty) return null;
    if (json['prerelease'] == true || json['draft'] == true) return null;

    Map<String, dynamic>? apkAsset;
    final assets = (json['assets'] as List?)?.cast<Map<String, dynamic>>();
    if (assets != null) {
      for (final a in assets) {
        final name = (a['name'] as String?)?.toLowerCase() ?? '';
        if (name.endsWith('.apk')) {
          apkAsset = a;
          break;
        }
      }
    }
    // Release docs-only (sem asset .apk) não conta — força o fallback à lista.
    if (apkAsset == null) return null;

    // ponytail: digest (SHA-1) direto do objeto asset da API; senão procura
    // um sha256 com 64 hex no body da release. Sem digest → sem verificação.
    String? digest;
    final assetDigest = (apkAsset['digest'] as String?) ?? '';
    if (assetDigest.isNotEmpty) {
      final colon = assetDigest.indexOf(':');
      // "sha1:abcd..." ou hex puro.
      digest = colon >= 0 ? assetDigest.substring(colon + 1) : assetDigest;
    } else {
      final body = (json['body'] as String?) ?? '';
      final m = RegExp(r'\b[a-fA-F0-9]{64}\b').firstMatch(body);
      if (m != null) digest = m.group(0);
    }

    return ReleaseInfo(
      tagName: tagName,
      versionLabel: (json['name'] as String?)?.isNotEmpty == true
          ? json['name'] as String
          : json['tag_name'] as String?,
      changelog: json['body'] as String?,
      apkUrl: apkAsset['browser_download_url'] is String
          ? Uri.parse(apkAsset['browser_download_url'] as String)
          : null,
      apkSize: apkAsset['size'] as int?,
      apkDigest: digest,
      isPrerelease: json['prerelease'] == true,
      isDraft: json['draft'] == true,
    );
  }
}

/// Resultado de [fetchLatestRelease]: a release candidata (ou null) e se a
/// checagem obteve resposta HTTP válida — o throttle só deve ser gravado
/// quando `httpOk` for true (D4: 403/429/erro de rede não "trancam" 24h).
class ReleaseCheckResult {
  final ReleaseInfo? info;
  final bool httpOk;
  const ReleaseCheckResult(this.info, this.httpOk);
}

/// Busca a última release com asset `.apk` do repositório.
///
/// Caminho rápido: `GET /releases/latest`. Se essa for *docs-only* (sem APK),
/// cai para `GET /releases?per_page=20` e toma a última com asset `.apk`
/// (correção D1 do plano v2).
///
/// Nunca lança exceção: erros de rede/HTTP são "sem update" silencioso.
Future<ReleaseCheckResult> fetchLatestRelease({http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final latest = await _getJson(c, '/releases/latest');
    if (latest.$2) {
      final latestRaw = latest.$1;
      if (latestRaw is Map<String, dynamic>) {
        final info = ReleaseInfo.tryParse(latestRaw);
        if (info != null) return ReleaseCheckResult(info, true);
      } else if (latestRaw == null) {
        // 404: repositório sem releases — checagem válida e silenciosa.
        return const ReleaseCheckResult(null, true);
      }
    }

    final list = await _getJson(c, '/releases?per_page=20');
    if (list.$2) {
      final listRaw = list.$1;
      if (listRaw is List) {
        // per_page retorna do mais novo para o mais velho — acha a primeira
        // com APK (releases/latest docs-only cai neste caminho).
        for (final r in listRaw.cast<Map<String, dynamic>>()) {
          final info = ReleaseInfo.tryParse(r);
          if (info != null) return ReleaseCheckResult(info, true);
        }
        // 200 com lista sem APK: checagem válida, sem update.
        return const ReleaseCheckResult(null, true);
      }
    }

    return const ReleaseCheckResult(null, false);
  } catch (e) {
    // ignore: avoid_print
    print('[updater] github_release_api error: $e');
    return const ReleaseCheckResult(null, false);
  } finally {
    if (client == null) c.close();
  }
}

/// GET com headers obrigatórios da API. Retorna `(corpo, ok)`.
/// `ok=false` → erro de rede/403/429/5xx/timeout (não conta como checagem
/// válida para o throttle). `ok=true, corpo=null` → 404 (sem releases).
Future<(Object?, bool)> _getJson(http.Client c, String path) async {
  final uri =
      Uri.parse('${UpdateConstants.apiBase}/repos/${UpdateConstants.repoSlug}$path');
  try {
    final res = await c.get(uri, headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': AppConstants.userAgent,
      'X-GitHub-Api-Version': '2022-11-28',
    }).timeout(AppConstants.requestTimeout);

    if (res.statusCode == 404) return (null, true);
    if (res.statusCode != 200) return (null, false);
    return (jsonDecode(utf8.decode(res.bodyBytes)), true);
  } catch (e) {
    // ignore: avoid_print
    print('[updater] github_release_api request error: $e');
    return (null, false);
  }
}