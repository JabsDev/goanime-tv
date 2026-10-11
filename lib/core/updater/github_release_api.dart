import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'update_constants.dart';
import 'version_compare.dart';

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

/// Constrói um ReleaseInfo "bloqueado" (não-instalável) apenas quando a
/// release é candidata a feedback: tag válida, NÃO draft, e não-instalável
/// (docs-only sem asset .apk ou prerelease). Retorna null caso contrário.
///
/// NOTA: viola deliberadamente o invariante de [ReleaseInfo] ("só releases
/// instaláveis") — por isso este tipo só circula em `blockedNewer` e jamais
/// é passado a `downloadAndInstall`/`pending`.
ReleaseInfo? _blockedFrom(Map<String, dynamic> json) {
  final tagName = json['tag_name'] as String?;
  if (tagName == null || tagName.isEmpty) return null;
  if (json['draft'] == true) return null;
  // Se é instalável, não é "bloqueado".
  if (ReleaseInfo.tryParse(json) != null) return null;
  final prerelease = json['prerelease'] == true;
  return ReleaseInfo(
    tagName: tagName,
    versionLabel: (json['name'] as String?)?.isNotEmpty == true
        ? json['name'] as String
        : json['tag_name'] as String?,
    changelog: json['body'] as String?,
    apkUrl: null,
    isPrerelease: prerelease,
    isDraft: false,
  );
}

/// Resultado de [fetchLatestRelease]: a release candidata (ou null) e se a
/// checagem obteve resposta HTTP válida — o throttle só deve ser gravado
/// quando `httpOk` for true (D4: 403/429/erro de rede não "trancam" 24h).
class ReleaseCheckResult {
  final ReleaseInfo? info;
  final bool httpOk;
  /// Release mais nova vista que NÃO é instalável pelo app (docs-only sem
  /// asset .apk, ou prerelease). Serve APENAS para feedback ("versão nova
  /// ainda não disponível") — NUNCA para oferecer download. Drafts nunca
  /// são capturados. Só é setado em checagens com httpOk == true.
  final ReleaseInfo? blockedNewer;
  const ReleaseCheckResult(this.info, this.httpOk, {this.blockedNewer});
}

/// Busca a última release com asset `.apk` do repositório.
///
/// **Por que não basta o `/releases/latest`:** o GitHub nem sempre devolve
/// ali a release mais nova. Medido em 11/10/2026 neste repositório, logo
/// depois de promover v1.5.5+1000083 de pre-release para release:
/// `/releases/latest` continuou devolvendo **v1.4.7+1000073**, quatro
/// versões atrás. Como o caminho rápido devolvia algo instalável, o app
/// parava ali e nunca olhava a lista — travando toda atualização futura
/// em silêncio.
///
/// Então: consulta os dois, junta os candidatos instaláveis e escolhe pelo
/// **maior build number** (`vX.Y.Z+N`), não pela ordem do JSON.
/// `prerelease`/`draft` sem APK vão para `blockedNewer` (só feedback).
///
/// Nunca lança exceção: erros de rede/HTTP são "sem update" silencioso.
Future<ReleaseCheckResult> fetchLatestRelease({http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    ReleaseInfo? blocked;
    final candidates = <ReleaseInfo>[];
    // Alguma requisição respondeu com HTTP válido? Se nem `/latest` nem a
    // lista responderam (403/429/timeout), isto é checagem INVÁLIDA: o
    // chamador não pode gravar o throttle de 24h, senão uma falha
    // transitória da API tranca o app sem atualização por um dia (D4).
    var anyOk = false;

    final latest = await _getJson(c, '/releases/latest');
    if (latest.$2) {
      anyOk = true;
      if (latest.$1 is Map<String, dynamic>) {
        final latestRaw = latest.$1 as Map<String, dynamic>;
        final info = ReleaseInfo.tryParse(latestRaw);
        if (info != null) {
          candidates.add(info);
        } else {
          blocked ??= _blockedFrom(latestRaw);
        }
      } else if (latest.$1 == null) {
        // 404: repositório sem releases — checagem válida e silenciosa.
        return const ReleaseCheckResult(null, true);
      }
    }

    final list = await _getJson(c, '/releases?per_page=20');
    if (list.$2 && list.$1 is List) {
      anyOk = true;
      for (final r in (list.$1 as List).cast<Map<String, dynamic>>()) {
        final info = ReleaseInfo.tryParse(r);
        if (info != null) {
          candidates.add(info);
          continue;
        }
        blocked ??= _blockedFrom(r);
      }
    }

    if (candidates.isEmpty) {
      // HTTP válido mas nada instalável → "sem update" (pode ter blocked).
      // Nenhum HTTP válido → erro de API, não trancar o throttle.
      return ReleaseCheckResult(null, anyOk, blockedNewer: anyOk ? blocked : null);
    }
    return ReleaseCheckResult(
      _newestByBuild(candidates),
      true,
      blockedNewer: blocked,
    );
  } catch (e) {
    // ignore: avoid_print
    print('[updater] github_release_api error: $e');
    return const ReleaseCheckResult(null, false);
  } finally {
    if (client == null) c.close();
  }
}

/// Release de maior build number. Tag sem `+N` perde para uma com `+N`
/// (o build é o critério autoritativo do projeto); empate/desempate vai
/// para a primeira da lista.
ReleaseInfo _newestByBuild(List<ReleaseInfo> candidates) {
  var best = candidates.first;
  var bestBuild = parseBuildNumber(best.tagName);
  for (final c in candidates.skip(1)) {
    final b = parseBuildNumber(c.tagName);
    if (b == null) continue; // sem build: nunca ganha de uma com build
    if (bestBuild == null || b > bestBuild) {
      best = c;
      bestBuild = b;
    }
  }
  return best;
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