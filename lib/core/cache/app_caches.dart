import 'package:flutter/foundation.dart';
import 'ttl_cache.dart';

/// App-wide cache instances with tuned TTLs.
///
/// - Search results are cached for a moderate window so navigating back and
///   forth between screens does not trigger new network requests.
/// - Episode lists are more stable and cached for longer.
/// - AniList enrichment metadata rarely changes, so it is cached for a day.
class AppCaches {
  static final TtlCache search = TtlCache(
    defaultTtl: const Duration(minutes: 30),
    maxSize: 100,
  );

  static final TtlCache episodes = TtlCache(
    defaultTtl: const Duration(hours: 1),
    maxSize: 200,
  );

  static final TtlCache enrichment = TtlCache(
    defaultTtl: const Duration(hours: 24),
    maxSize: 500,
  );

  static final TtlCache httpResponses = TtlCache(
    defaultTtl: const Duration(minutes: 5),
    maxSize: 400,
  );

  static void clearAll() {
    search.clear();
    episodes.clear();
    enrichment.clear();
    httpResponses.clear();
    if (kDebugMode) debugPrint('[AppCaches] Cleared all caches');
  }
}
