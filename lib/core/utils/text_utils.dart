/// Shared text-normalization helpers used by the scrapers.
class TextUtils {
  const TextUtils._();

  /// Converts a search query into the slug format used by some sources.
  static String treatName(String name) {
    return name.toLowerCase().replaceAll(' ', '-');
  }

  /// Strips common suffixes/tags added by scrapers so the same title is
  /// detected as a duplicate before hitting the AniList API.
  static String cleanTitle(String title) {
    String cleaned = title;
    cleaned = cleaned.replaceAll(
      RegExp(r'[🔥🌐]?\[(?:animefire|allanime)\]\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'(?:dublado|legendado|dub|sub)\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'todos\s+os\s+episodios', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+\d+(\.\d+)?\s+A\d+\s*$'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+\d+(\.\d+)?\s*$'), '');
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*\([^)]*(?:dublado|legendado|dub|sub)[^)]*\)',
          caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*\(\d+\s+(?:episodes?|eps)\)'),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned;
  }

  /// Extracts the season segment from a SuperFlix episode URL.
  static String? extractSuperFlixSeason(String url, String? tmdbId) {
    if (tmdbId == null) return null;
    final pattern = RegExp('/serie/$tmdbId/(\\d+)/');
    final match = pattern.firstMatch(url);
    return match?.group(1);
  }
}
