/// Extracts real episode numbers from provider/catalog data so the grid is
/// never numbered by array position.
///
/// Titles always carry the number ("Episode 130 - …", "EP 1 · …", "Ep. 12: …",
/// "Episódio 5 - …", pt-BR included); URLs carry it in the last numeric segment
/// ("/animes/black-clover/1").
library;

final RegExp _specialRe = RegExp(
  r'\b(special|especial|ova|movie|film|gaiden|recap|pirate)\b',
  caseSensitive: false,
);

final RegExp _titleNumberRe = RegExp(
  r'\b(?:ep(?:isode)?|epis[óo]dio)\.?\s*(\d+)',
  caseSensitive: false,
);

int? episodeNumberFromTitle(String title) {
  if (title.isEmpty) return null;
  // Specials/OVAs/Movies are not numbered entries of the series grid; their
  // number would collide with the main episode sequence (e.g. "Movie 5").
  if (_specialRe.hasMatch(title)) return null;
  final m = _titleNumberRe.firstMatch(title);
  return m == null ? null : int.tryParse(m.group(1)!);
}

int? episodeNumberFromUrl(String url) {
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  for (final seg in uri.pathSegments.reversed) {
    final n = int.tryParse(seg);
    if (n != null) return n;
  }
  return null;
}