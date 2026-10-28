import '../../data/models/episode.dart';

/// Fase 3: "melhor qualidade automática". Escolhe o índice da melhor qualidade
/// de uma lista de fontes e, quando o usuário não escolhe explicitamente, o
/// player abre direto na melhor em vez de exigir mais um tap no diálogo.
///
/// Parser lazyl: primeiro número de 3-4 dígitos da string ("1080p"→1080,
/// "720p"→720). Sem número, cai na heurística ("FHD"=1080, "HD"=720) e termina
/// em 0 para rótulos tipo "Auto" (nesse caso o mpv decide a bitrate).
int bestQualityIndex(List<VideoSource> sources) {
  if (sources.length <= 1) return 0;
  var best = 0;
  var bestScore = -1;
  for (var i = 0; i < sources.length; i++) {
    final score = qualityScore(sources[i].quality);
    if (score > bestScore) {
      bestScore = score;
      best = i;
    }
  }
  return best;
}

/// Ordena estável com a melhor qualidade primeiro — o auto-next (sem escolha
/// explícita) abre direto na melhor em vez de exigir mais um tap no diálogo.
List<VideoSource> sortBestFirst(List<VideoSource> sources) {
  final list = [...sources];
  list.sort(
    (a, b) => qualityScore(b.quality).compareTo(qualityScore(a.quality)),
  );
  return list;
}

/// Teto do "padrão" em aparelho fraco (modo lite): 720p. O painel desses
/// projetores/TV sticks é 720p — 1080p só triplica decode/bitrate.
const int kDefaultMaxQualityHeight = 720;

/// Índice da qualidade PADRÃO numa lista de fontes (ordem indiferente).
///
/// Regra: a melhor qualidade que **não passe** de [maxHeight]. O teto é
/// preferência, nunca bloqueio: se a fonte só oferece acima do teto (ex.: só
/// 1080p), devolve a **menor** disponível — o episódio toca igual, sem
/// transcodificar nada. `maxHeight == null` = sem teto (melhor qualidade).
///
/// Rótulo sem número ("Auto") pontua 0 e conta como "abaixo do teto": só é
/// escolhido quando não há resolução numérica melhor dentro do limite.
int defaultQualityIndex(List<VideoSource> sources, {int? maxHeight}) {
  if (sources.length <= 1) return 0;
  if (maxHeight == null) return bestQualityIndex(sources);
  int? withinCap;
  int? smallestAboveCap;
  for (var i = 0; i < sources.length; i++) {
    final score = qualityScore(sources[i].quality);
    if (score <= maxHeight) {
      if (withinCap == null ||
          score > qualityScore(sources[withinCap].quality)) {
        withinCap = i;
      }
    } else if (smallestAboveCap == null ||
        score < qualityScore(sources[smallestAboveCap].quality)) {
      smallestAboveCap = i;
    }
  }
  // Sem nada dentro do teto: toca o mais leve que existe (nunca falha).
  return withinCap ?? smallestAboveCap ?? 0;
}

/// Índice de reprodução numa lista JÁ ordenada por [sortBestFirst].
///
/// [requested] é o índice da escolha explícita do usuário na lista ORIGINAL
/// (antes da ordenação) — é remapeado por identidade e, após um re-resolve do
/// retry, por qualidade+url (o retry repete a MESMA qualidade, nunca "pula"
/// sozinho). `requested == null` = não houve escolha (auto-next, card de
/// legenda IA, fallback): aplica [maxHeight] como teto do padrão.
int resolveStartIndex(
  List<VideoSource> ordered,
  List<VideoSource> original, {
  required int? requested,
  int? maxHeight,
}) {
  if (ordered.isEmpty) return 0;
  if (requested == null) {
    return defaultQualityIndex(ordered, maxHeight: maxHeight);
  }
  final clamped = requested < 0 || requested >= original.length ? 0 : requested;
  final chosen = original[clamped];
  final byIdentity = ordered.indexWhere((s) => identical(s, chosen));
  if (byIdentity >= 0) return byIdentity;
  final byKey = ordered.indexWhere(
      (s) => s.quality == chosen.quality && s.url == chosen.url);
  return byKey >= 0 ? byKey : 0;
}

int qualityScore(String quality) {
  final n = RegExp(r'(\d{3,4})').firstMatch(quality);
  if (n != null) return int.parse(n.group(1)!);
  final q = quality.toLowerCase();
  if (q.contains('fhd') || q.contains('full hd')) return 1080;
  if (q.contains('hd')) return 720;
  return 0;
}
