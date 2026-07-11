class _CacheEntry<T> {
  final T value;
  final DateTime expiry;

  _CacheEntry(this.value, this.expiry);
}

/// A simple thread-safe in-memory cache with per-entry TTL and LRU-ish eviction.
class TtlCache {
  final Duration defaultTtl;
  final int maxSize;
  final Map<String, _CacheEntry<dynamic>> _store = {};

  TtlCache({this.defaultTtl = const Duration(minutes: 10), this.maxSize = 300});

  T? get<T>(String key) {
    final entry = _store[key];
    if (entry == null) return null;
    if (entry.expiry.isBefore(DateTime.now())) {
      _store.remove(key);
      return null;
    }
    // refresh recency
    _store.remove(key);
    _store[key] = entry;
    return entry.value;
  }

  void set<T>(String key, T value, {Duration? ttl}) {
    if (_store.length >= maxSize && !_store.containsKey(key)) {
      _store.remove(_store.keys.first);
    }
    _store[key] = _CacheEntry<T>(value, DateTime.now().add(ttl ?? defaultTtl));
  }

  bool contains(String key) => get<dynamic>(key) != null;

  void remove(String key) => _store.remove(key);

  void clear() => _store.clear();
}
