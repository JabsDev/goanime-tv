import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/anilist_models.dart';

/// Cache de sessão do token/usuário AniList em [SharedPreferences].
///
/// ponytail: NÃO é mais a fonte de verdade do token. A fonte é o perfil ativo
/// (`ProfileService`/`ProfileStore`), para o qual todas as leituras passam. Este
/// serviço só guarda um espelho de leitura rápida (`user`/`lists_cache`) e o
/// token global removido no logout — para não dessincronizar entre perfis.
class AnilistAuthService {
  static final _authKey = 'anilist_auth_token';
  static final _userKey = 'anilist_user_data';
  static final _listsKey = 'anilist_lists_cache';

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_authKey);
  }

  /// Cache puro: grava o token já validado (a validação acontece em
  /// `AniListService.saveToken` via Viewer). Sem fetch — persistência dura não
  /// mora aqui.
  static Future<bool> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_authKey, token);
    return true;
  }

  static Future<bool> removeToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_authKey);
    await removeUserData(_userKey);
    await prefs.remove(_listsKey);
    return true;
  }

  static Future<Map<String, dynamic>?> getUserData(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFor(key));
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> saveUserData(String key, Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final storageKey = _keyFor(key);
    await prefs.setString(storageKey, jsonEncode(data));
    return true;
  }

  static Future<bool> removeUserData(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFor(key));
    return true;
  }

  static Future<bool> isLoggedIn() async {
    return (await getToken()) != null;
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

  static String _keyFor(String key) {
    if (key == 'user') return _userKey;
    if (key == 'lists_cache') return _listsKey;
    return key;
  }
}