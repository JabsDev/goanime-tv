import '../../data/models/anime.dart';

/// Metrics for tracking anime availability across sources
class AnimeMetrics {
  final Map<String, Map<AnimeSource, int>> _availability = {};
  final Map<String, Map<AnimeSource, int>> _searches = {};

  AnimeMetrics._();

  factory AnimeMetrics() {
    return AnimeMetrics._();
  }

  /// Record availability result for an anime
  void recordAvailability(String animeName, AnimeSource source, bool available) {
    _availability.putIfAbsent(animeName, () => <AnimeSource, int>{});
    _availability[animeName]!.putIfAbsent(source, () => 0);
    _availability[animeName]![source] = (_availability[animeName]![source] ?? 0) + 1;
  }

  /// Record search attempt for an anime
  void recordSearch(String animeName, AnimeSource source, bool success) {
    _searches.putIfAbsent(animeName, () => <AnimeSource, int>{});
    _searches[animeName]!.putIfAbsent(source, () => 0);
    _searches[animeName]![source] = (_searches[animeName]![source] ?? 0) + 1;
  }

  /// Get availability report by source
  Map<String, dynamic> generateAvailabilityReport() {
    final bySource = <AnimeSource, Map<String, int>>{};

    for (final source in AnimeSource.values) {
      final byAnime = <String, int>{};
      for (final anime in _availability.keys) {
        final count = _availability[anime]![source] ?? 0;
        byAnime[anime] = count;
      }
      bySource[source] = byAnime;
    }

    return {
      'bySource': bySource,
      'totalAnimes': _availability.length,
      'generatedAt': DateTime.now().toIso8601String(),
    };
  }

  /// Get search report by source
  Map<String, dynamic> generateSearchReport() {
    final bySource = <AnimeSource, Map<String, int>>{};

    for (final source in AnimeSource.values) {
      final byAnime = <String, int>{};
      for (final anime in _searches.keys) {
        final count = _searches[anime]![source] ?? 0;
        byAnime[anime] = count;
      }
      bySource[source] = byAnime;
    }

    return {
      'bySource': bySource,
      'totalSearches': _searches.length,
      'generatedAt': DateTime.now().toIso8601String(),
    };
  }

  /// Get availability count for specific anime and source
  int getAvailabilityCount(String animeName, AnimeSource source) {
    final map = _availability[animeName];
    if (map == null) return 0;
    return map[source] ?? 0;
  }

  /// Get search count for specific anime and source
  int getSearchCount(String animeName, AnimeSource source) {
    final map = _searches[animeName];
    if (map == null) return 0;
    return map[source] ?? 0;
  }

  /// Clear all metrics
  void clear() {
    _availability.clear();
    _searches.clear();
  }
}
