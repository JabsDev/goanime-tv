/// Helpers to detect and describe episodes that haven't aired yet on currently
/// airing anime, using AniList's `nextAiringEpisode` (first not-yet-aired
/// number + `airingAt` epoch seconds) carried by [Anime] after enrichment.
library;

import '../../data/models/anime.dart';

/// Returns a user-facing message explaining that [tappedEpisode] hasn't aired
/// yet, or null when the episode is NOT a not-yet-aired case:
///
///  - no airing info available ([Anime.nextAiringEpisode] == null), or
///  - the tapped number is below the next airing one — the episode should
///    already exist, so the gap is a genuine source miss, not an airing wait.
///
/// [nextEpisode] is AniList `nextAiringEpisode.episode` and [nextAiringAt] the
/// predicted airing [DateTime] of that next episode (already local time). The
/// date shown is the predicted one for the NEXT episode — for taps exactly on
/// it that IS the episode's own date; for taps beyond it the user learns when
/// the series resumes.
String? notAiredMessage({
  required int tappedEpisode,
  required Anime anime,
  DateTime? now,
}) {
  final nextEpisode = anime.nextAiringEpisode;
  if (nextEpisode == null || tappedEpisode < nextEpisode) return null;

  final ref = now ?? DateTime.now();
  final base = 'O Episódio $tappedEpisode ainda não foi lançado.';
  final airingAt = anime.nextAiringAt;
  if (airingAt == null) return base;
  final at = DateTime.fromMillisecondsSinceEpoch(airingAt * 1000);

  if (tappedEpisode == nextEpisode) {
    return '$base Lançamento previsto: ${formatRelativeDate(at, ref)}.';
  }
  return '$base O próximo episódio (Ep $nextEpisode) está previsto para '
      '${formatRelativeDate(at, ref)}.';
}

/// Formats a predicted airing moment relative to [now] in PT-BR: "hoje às
/// 18:00", "amanhã às 18:00", "em 3 dias (26/08 às 18:00)" or the bare date.
String formatRelativeDate(DateTime at, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final diff = day.difference(today).inDays;
  final time =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return 'hoje às $time';
  if (diff == 1) return 'amanhã às $time';
  if (diff >= 2 && diff <= 7) return 'em $diff dias (${_ddmm(at)} às $time)';
  return '${_ddmmyyyy(at)} às $time';
}

String _ddmm(DateTime d) {
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm';
}

String _ddmmyyyy(DateTime d) {
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}