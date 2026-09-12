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

/// Ordena estável com a melhor qualidade primeiro — útil para o auto-avanço
/// do player (que percorre índices crescentes quando uma fonte morre) partir
/// da melhor e não da primeira que o scraper retornou.
List<VideoSource> sortBestFirst(List<VideoSource> sources) {
  final list = [...sources];
  list.sort(
    (a, b) => qualityScore(b.quality).compareTo(qualityScore(a.quality)),
  );
  return list;
}

int qualityScore(String quality) {
  final n = RegExp(r'(\d{3,4})').firstMatch(quality);
  if (n != null) return int.parse(n.group(1)!);
  final q = quality.toLowerCase();
  if (q.contains('fhd') || q.contains('full hd')) return 1080;
  if (q.contains('hd')) return 720;
  return 0;
}
