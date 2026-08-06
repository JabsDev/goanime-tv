/// Shared text-normalization helpers used by the scrapers.
class TextUtils {
  const TextUtils._();

  /// Converts a search query into the slug format used by some sources.
  static String treatName(String name) {
    return name.toLowerCase().replaceAll(' ', '-');
  }

  /// Generate name variations for better search matching
  static List<String> generateNameVariations(String animeName) {
    final variations = <String>[animeName];

    // Remove special characters
    var clean = animeName.replaceAll(RegExp(r'[^\w\s\-\(\)\[\]]'), '');
    clean = clean.replaceAll(RegExp(r'\s+'), ' ').trim();
    variations.add(clean);

    // Remove Portuguese articles
    final prefixes = ['o ', 'a ', 'o ', 'a ', 'un ', 'la ', 'le '];
    for (final prefix in prefixes) {
      if (clean.startsWith(prefix)) {
        variations.add(clean.substring(prefix.length));
      }
    }

    // Remove year from end
    final nameOnly = clean.replaceAll(RegExp(r'\d+$'), '');
    if (nameOnly.isNotEmpty && nameOnly != clean) {
      variations.add(nameOnly);
    }

    // Remove numbers from middle
    final noNumbers = clean.replaceAll(RegExp(r'\d+'), '');
    if (noNumbers.isNotEmpty && noNumbers != clean) {
      variations.add(noNumbers);
    }

    // Remove year
    final noYear = clean.replaceAll(RegExp(r'\d{4}'), '');
    if (noYear.isNotEmpty && noYear != clean) {
      variations.add(noYear);
    }

    // Remove spaces between words
    final noSpaces = clean.replaceAll(RegExp(r'\s+'), '');
    if (noSpaces.isNotEmpty && noSpaces != clean) {
      variations.add(noSpaces);
    }

    // Lowercase/uppercase
    variations.add(animeName.toLowerCase());
    variations.add(animeName.toUpperCase());

    // Remove apostrophes
    final noApostrophe = animeName.replaceAll("'", '');
    if (noApostrophe.isNotEmpty && noApostrophe != animeName) {
      variations.add(noApostrophe);
    }

    // Remove dashes
    final noDashes = animeName.replaceAll('-', ' ');
    if (noDashes.isNotEmpty && noDashes != animeName) {
      variations.add(noDashes);
    }

    // Normalize spaces
    final normalized = clean.replaceAll(RegExp(r'\s+'), ' ').trim();
    variations.add(normalized);

    // Remove dictionary suffix
    final noDictionary = normalized.replaceAll(' - Dicionário', '');
    if (noDictionary.isNotEmpty && noDictionary != normalized) {
      variations.add(noDictionary);
    }

    return variations.toSet().toList();
  }

  /// Strips common suffixes/tags added by scrapers so the same title is
  /// detected as a duplicate before hitting the AniList API.
  ///
  /// Applied at the SOURCE (parsers) since B1, so it must not mangle legit
  /// names: bare trailing integers are kept (a "Psycho-Pass 2" is a real
  /// title) and sub/dub words only match on word boundaries (so "Subarashii
  /// Sekai" survives).
  static String cleanTitle(String title) {
    String cleaned = title;
    cleaned = cleaned.replaceAll(
      RegExp(r'[🔥🌐]?\[(?:animefire|allanime)\]\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\b(?:dublado|legendado|dub|sub)\b\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'todos\s+os\s+episodios', caseSensitive: false),
      '',
    );
    // nota + faixa etária anexadas pelo site ("7.34  A14"). A nota sempre
    // carrega decimal; inteiro sozinho no fim pode ser temporada real.
    cleaned = cleaned.replaceAll(
        RegExp(r'\s+\d+(?:\.\d+)?\s+A\d+\s*$', caseSensitive: false), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+\d+\.\d+\s*$'), '');
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*\([^)]*(?:dublado|legendado|dub|sub)[^)]*\)',
          caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*\(\d+\s+(?:episodes?|eps)\)'),
      '',
    );
    // qualificador " (TV)" de temporada no fim.
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*\(tv\)\s*$', caseSensitive: false),
      '',
    );
    // parens vazios deixados por remoções ("(Dublado)" → "()").
    cleaned = cleaned.replaceAll(RegExp(r'\s*\(\)'), '');
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

/// Kotlin-style string helpers used by scrapers for quick substring extraction.
extension StringScraping on String {
  String substringAfter(String delimiter) {
    final idx = indexOf(delimiter);
    return idx == -1 ? this : substring(idx + delimiter.length);
  }

  String substringBefore(String delimiter) {
    final idx = indexOf(delimiter);
    return idx == -1 ? this : substring(0, idx);
  }
}
