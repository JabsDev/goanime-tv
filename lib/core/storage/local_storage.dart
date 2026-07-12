import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalStorage {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('[LocalStorage] Error initializing: $e');
      rethrow;
    }
  }

  static void ensureInitialized() {
    if (_prefs == null) {
      throw Exception('LocalStorage not initialized. Call init() first.');
    }
  }

  static bool isInitialized() => _prefs != null;

  static Future<void> saveWatchProgress({
    required String animeKey,
    required int episodeNumber,
    required Duration position,
    required int totalEpisodes,
  }) async {
    ensureInitialized();
    final data = {
      'episode': episodeNumber,
      'position': position.inMilliseconds,
      'totalEpisodes': totalEpisodes,
    };
    await _prefs?.setString('progress_$animeKey', jsonEncode(data));
  }

  static Map<String, dynamic>? getWatchProgress(String animeKey) {
    ensureInitialized();
    final raw = _prefs?.getString('progress_$animeKey');
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static Future<void> addToHistory({
    required String animeKey,
    required String title,
    required String imageUrl,
    required int lastEpisode,
    required int totalEpisodes,
  }) async {
    ensureInitialized();
    final history = getHistory();
    history.removeWhere((e) => e['key'] == animeKey);
    history.insert(0, {
      'key': animeKey,
      'title': title,
      'image': imageUrl,
      'lastEpisode': lastEpisode,
      'totalEpisodes': totalEpisodes,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (history.length > 50) history.removeRange(50, history.length);
    await _prefs?.setString('history', jsonEncode(history));
  }

  static List<Map<String, dynamic>> getHistory() {
    ensureInitialized();
    final raw = _prefs?.getString('history');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  static Future<void> toggleFavorite({
    required String animeKey,
    required String title,
    required String imageUrl,
  }) async {
    ensureInitialized();
    final favorites = getFavorites();
    final idx = favorites.indexWhere((e) => e['key'] == animeKey);
    if (idx >= 0) {
      favorites.removeAt(idx);
    } else {
      favorites.add({
        'key': animeKey,
        'title': title,
        'image': imageUrl,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
    await _prefs?.setString('favorites', jsonEncode(favorites));
  }

  static List<Map<String, dynamic>> getFavorites() {
    ensureInitialized();
    final raw = _prefs?.getString('favorites');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  static bool isFavorite(String animeKey) {
    return getFavorites().any((e) => e['key'] == animeKey);
  }

  // ---------------------------------------------------------------------------
  // Token storage (used by AniListService)
  // ---------------------------------------------------------------------------

  /// Saves an AniList access token. Returns true on success.
  static Future<bool> saveToken(String token) async {
    ensureInitialized();
    if (!token.startsWith('eyJ')) return false;
    await _prefs?.setString('anilist_token', token);
    return true;
  }

  /// Reads the stored AniList access token, or null if none.
  static String? getToken() {
    ensureInitialized();
    return _prefs?.getString('anilist_token');
  }

  /// Removes the stored AniList access token.
  static Future<void> removeToken() async {
    ensureInitialized();
    await _prefs?.remove('anilist_token');
  }

  /// Saves user data (e.g. AniList user profile) under [key].
  static Future<bool> saveUserData(String key, Map<String, dynamic> data) async {
    ensureInitialized();
    if (_prefs == null) return false;
    return await _prefs!.setString('anilist_$key', jsonEncode(data));
  }

  /// Reads user data saved under [key], or null if none.
  static Map<String, dynamic>? getUserData(String key) {
    ensureInitialized();
    final raw = _prefs?.getString('anilist_$key');
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Removes user data stored under [key].
  static Future<void> removeUserData(String key) async {
    ensureInitialized();
    await _prefs?.remove('anilist_$key');
  }
}
