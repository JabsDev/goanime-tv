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

  /// Canonical catalog episode lists, keyed by anime identity (anilistId or
  /// cleaned title). Stable — AniList metadata rarely changes.
  static final TtlCache catalog = TtlCache(
    defaultTtl: const Duration(hours: 24),
    maxSize: 200,
  );

  /// Per-(anime, episode) provider resolutions. URLs expire, so the TTL is short.
  static final TtlCache resolutions = TtlCache(
    defaultTtl: const Duration(minutes: 30),
    maxSize: 300,
  );

  // In-memory cache for HTTP responses to prevent caching errors
  static final Map<String, List<int>> _httpCache = {};
  static final Map<String, DateTime> _httpExpiry = {};

  static void clearAll() {
    search.clear();
    episodes.clear();
    enrichment.clear();
    httpResponses.clear();
    catalog.clear();
    resolutions.clear();
    _httpCache.clear();
    _httpExpiry.clear();
    if (kDebugMode) debugPrint('[AppCaches] Cleared all caches');
  }

  // Clears cache for a specific URL
  static void clear(String url) {
    final key = 'GET:$url:';
    _httpCache.removeWhere((k, v) => k.startsWith(key));
    _httpExpiry.removeWhere((k, _) => k.startsWith(key));
    if (kDebugMode) debugPrint('[AppCaches] Cleared cache for: $url');
  }

  // Clears cache for a specific host/domain
  static void clearByHost(String host) {
    _httpCache.removeWhere((key, _) => key.contains(host));
    _httpExpiry.removeWhere((key, _) => key.contains(host));
    if (kDebugMode) debugPrint('[AppCaches] Cleared cache by host: $host');
  }

  // Sets HTTP response with error handling - doesn't cache error codes
  static void setWithErrorHandling(
    String key,
    List<int> body,
    int statusCode,
  ) {
    // Only cache successful responses and redirects
    // Don't cache 403, 404, 500, etc.
    if (statusCode != 200 && statusCode != 301) {
      if (kDebugMode) debugPrint('[AppCaches] Not caching error status: $statusCode');
      return;
    }
    _httpCache[key] = body;
    _httpExpiry[key] = DateTime.now().add(const Duration(minutes: 5));
  }

  // Gets HTTP response from cache with expiry check
  static List<int>? get(String key) {
    final expiry = _httpExpiry[key];
    if (expiry != null && DateTime.now().isAfter(expiry)) {
      _httpCache.remove(key);
      _httpExpiry.remove(key);
      if (kDebugMode) debugPrint('[AppCaches] Cache expired for: $key');
      return null;
    }
    return _httpCache[key];
  }

  // Clears cache with error handling for error status codes
  static void clearErrors(String url) {
    final key = 'GET:$url:';
    _httpCache.removeWhere((k, v) => k.startsWith(key));
    _httpExpiry.removeWhere((k, _) => k.startsWith(key));
    
    // Also clear by host for broader cleanup
    final host = Uri.parse(url).host;
    clearByHost(host);
    
    if (kDebugMode) debugPrint('[AppCaches] Cleared errors for: $url');
  }
}
