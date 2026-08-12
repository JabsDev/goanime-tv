/// Comparação de versões com base na convenção de tag do projeto.
///
/// Tags de release: `vX.Y.Z+BUILD` (ex.: `v1.0.1+1000001`). A chave
/// autoritativa é o **build number** (`+N`), monotônico. Tags sem `+N` caem em
/// comparação semver simples (MAJOR → MINOR → PATCH). Tags malformadas nunca
/// lançam exceção — são tratadas como "não atualizar".

/// Extrai o build number de uma tag `vX.Y.Z+N`. Null se a tag não tiver `+N`.
int? parseBuildNumber(String tagName) {
  final t = tagName.trim();
  if (t.isEmpty) return null;
  final cleaned =
      (t.startsWith('v') || t.startsWith('V')) ? t.substring(1) : t;
  final plus = cleaned.lastIndexOf('+');
  if (plus <= 0 || plus == cleaned.length - 1) return null;
  final build = int.tryParse(cleaned.substring(plus + 1).trim());
  return build;
}

/// Versão sem `+N` usada na exibição/referência (ex.: `v1.0.1+1000001` → `1.0.1`).
String versionLabelFromTag(String tagName) {
  final t = tagName.trim();
  final cleaned =
      (t.startsWith('v') || t.startsWith('V')) ? t.substring(1) : t;
  final plus = cleaned.indexOf('+');
  return plus > 0 ? cleaned.substring(0, plus) : cleaned;
}

/// Compara a release da tag [tagName] com a versão instalada.
/// Retorna > 0 → release é mais nova; <= 0 → não atualizar.
int compareAppVersions({
  required int installedBuild,
  required String installedVersion,
  required String tagName,
}) {
  final build = parseBuildNumber(tagName);
  if (build != null) return build.compareTo(installedBuild);

  // Fallback: tag sem `+N` → semver simples.
  final tagVer = _parseSemver(versionLabelFromTag(tagName));
  final inst = _parseSemver(installedVersion);
  if (tagVer == null || inst == null) return 0; // malformada → não atualiza
  for (var i = 0; i < 3; i++) {
    if (tagVer[i] != inst[i]) return tagVer[i] > inst[i] ? 1 : -1;
  }
  return 0;
}

/// `[major, minor, patch]`, com ausentes tratados como 0. Null se não for
/// possível extrair nenhum número.
List<int>? _parseSemver(String v) {
  final cleaned = v.trim();
  if (cleaned.isEmpty) return null;
  final parts = cleaned.split('.');
  if (parts.isEmpty) return null;
  final out = <int>[];
  for (final p in parts) {
    if (out.length == 3) break;
    final n = int.tryParse(p.trim());
    if (n == null) {
      if (out.isEmpty) return null;
      out.add(0);
      break;
    }
    out.add(n);
  }
  while (out.length < 3) {
    out.add(0);
  }
  return out;
}