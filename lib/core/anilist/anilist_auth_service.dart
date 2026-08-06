import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../profile/profile_store.dart';
import '../../data/models/anilist_models.dart';

/// Manages AniList authentication tokens and user data
class AnilistAuthService {
  static final _authKey = 'anilist_auth_token';
  static final _userDataKey = 'anilist_user_data';

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_authKey);
  }

  static Future<bool> saveToken(String token) async {
    if (!token.startsWith('eyJ')) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_authKey, token);
    final user = await _fetchUser(token);
    if (user != null) {
      await saveUserData('user', {
        'id': user.id,
        'name': user.name,
        'avatar': user.avatar,
      });
      return true;
    }
    await removeToken();
    return false;
  }

  static Future<bool> removeToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_authKey);
    await removeUserData('user');
    return true;
  }
 
  static Future<Map<String, dynamic>?> getUserData(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(key);
    if (value == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(value));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> saveUserData(String key, Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(data));
    return true;
  }

  static Future<bool> removeUserData(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
    return true;
  }

  static Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null;
  }

  static Future<AniListUser?> getUser() async {
    final data = await getUserData('user');
    if (data == null) return null;
    try {
      return AniListUser.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  static Future<AniListUser?> _fetchUser(String token) async {
    return null; // Placeholder - actual implementation would call API
  }

  static Future<bool> refreshUser() async {
    final token = await getToken();
    if (token == null) return false;
    final user = await _fetchUser(token);
    if (user != null) {
      await saveUserData('user', {
        'id': user.id,
        'name': user.name,
        'avatar': user.avatar,
      });
      return true;
    }
    await removeToken();
    return false;
  }
}