import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/anime.dart';
import '../utils/text_utils.dart';

/// Persistent mapping anime identity → provider page URL.
///
/// The costly, fragile step when resolving an episode is "find this anime's
/// page on provider X" (search-by-name + Cloudflare/429). Per the review (D4)
/// that discovery must be PERSISTED — an in-RAM cache would be rebuilt on every
/// cold start, re-paying the search and re-feeding AnimeFire's rate limit.
///
/// This is a simple key-value discovery store keyed by a stable identity
/// (anilistId, or the cleaned title when there is no AniList id):
///
///   identity -> { animeFire: 'https://...', goyabu: 'https://...', ... }
///
/// It does not replace the short-TTL availability/resolution caches; it
/// complements them.
class ProviderMatchStore {
  static const _prefKey = 'provider_matches_v1';

  static Map<String, Map<String, String>>? _cache;

  /// Stable identity for [anime]: AniList id when available, else the cleaned
  /// title. Using the id avoids title drift across providers.
  static String identity(Anime anime) =>
      anime.anilistId?.toString() ?? TextUtils.cleanTitle(anime.name);

  static Future<Map<String, Map<String, String>>> _ensure() async {
    if (_cache == null) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) {
        _cache = {};
      } else {
        try {
          _cache = (jsonDecode(raw) as Map<String, dynamic>).map((k, v) =>
              MapEntry(k,
                  (v as Map).map((s, u) => MapEntry(s, u.toString()))));
        } catch (e) {
          _cache = {};
        }
      }
    }
    return _cache!;
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(_cache));
  }

  /// The last known provider-page URL for [identity] on [source]; null on
  /// first hit.
  static Future<String?> urlFor(String identity, AnimeSource source) async {
    final map = await _ensure();
    return map[identity]?[source.name];
  }

  /// Persists the provider-page match so later taps resolve without searching.
  static Future<void> saveMatch(
      String identity, AnimeSource source, String url) async {
    final map = await _ensure();
    final entry = map.putIfAbsent(identity, () => {});
    entry[source.name] = url;
    await _persist();
  }

  /// Drops a stale match (e.g. when the provider returns 404) so next tap
  /// re-discovers instead of replaying a dead page.
  static Future<void> removeMatch(String identity, AnimeSource source) async {
    final map = await _ensure();
    map[identity]?.remove(source.name);
    await _persist();
  }
}