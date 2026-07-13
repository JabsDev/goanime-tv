import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/cache/ttl_cache.dart';

void main() {
  group('TtlCache', () {
    test('get returns value when not expired', () {
      final cache = TtlCache(defaultTtl: const Duration(minutes: 10));
      cache.set('key1', 'value1');
      expect(cache.get<String>('key1'), equals('value1'));
    });

    test('get returns null after TTL expires', () async {
      final cache = TtlCache(defaultTtl: const Duration(milliseconds: 5));
      cache.set('key1', 'value1');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(cache.get<String>('key1'), isNull);
    });

    test('evicts oldest entry when at max capacity', () {
      final cache = TtlCache(
        defaultTtl: const Duration(minutes: 10),
        maxSize: 2,
      );
      cache.set('key1', 'value1');
      cache.set('key2', 'value2');
      // key1 was inserted first, so it should be evicted when key3 is added
      cache.set('key3', 'value3');

      expect(cache.get<String>('key1'), isNull);
      expect(cache.get<String>('key2'), equals('value2'));
      expect(cache.get<String>('key3'), equals('value3'));
    });

    test('contains returns false for missing or expired keys', () async {
      final cache = TtlCache(defaultTtl: const Duration(milliseconds: 5));

      // missing key
      expect(cache.contains('missing'), isFalse);

      // set key, then immediately check
      cache.set('key1', 'value1');
      expect(cache.contains('key1'), isTrue);

      // wait past TTL
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(cache.contains('key1'), isFalse);
    });

    test('remove clears a single entry', () {
      final cache = TtlCache(defaultTtl: const Duration(minutes: 10));
      cache.set('key1', 'value1');
      cache.set('key2', 'value2');

      cache.remove('key1');

      expect(cache.get<String>('key1'), isNull);
      expect(cache.get<String>('key2'), equals('value2'));
    });

    test('clear empties all entries', () {
      final cache = TtlCache(defaultTtl: const Duration(minutes: 10));
      cache.set('key1', 'value1');
      cache.set('key2', 'value2');

      cache.clear();

      expect(cache.get<String>('key1'), isNull);
      expect(cache.get<String>('key2'), isNull);
    });

    test('per-entry TTL overrides default', () async {
      final cache = TtlCache(defaultTtl: const Duration(minutes: 10));
      cache.set('short', 'short-lived', ttl: const Duration(milliseconds: 5));
      cache.set('long', 'long-lived');

      await Future<void>.delayed(const Duration(milliseconds: 15));

      // short entry should be expired
      expect(cache.get<String>('short'), isNull);
      // long entry should still be valid
      expect(cache.get<String>('long'), equals('long-lived'));
    });

    test('get refreshes recency on access', () {
      final cache = TtlCache(
        defaultTtl: const Duration(minutes: 10),
        maxSize: 2,
      );
      cache.set('key1', 'value1');
      cache.set('key2', 'value2');

      // access key1 to refresh its recency
      cache.get<String>('key1');

      // adding a third entry should evict key2 (not key1, since key1 was accessed)
      cache.set('key3', 'value3');

      expect(cache.get<String>('key1'), equals('value1'));
      expect(cache.get<String>('key2'), isNull);
      expect(cache.get<String>('key3'), equals('value3'));
    });
  });
}
