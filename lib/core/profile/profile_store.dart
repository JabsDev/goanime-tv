import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/profile.dart';

class ProfileStore {
  static final ProfileStore instance = ProfileStore._();
  ProfileStore._();

  static const _kCurrentProfileId = 'current_profile_id';

  Directory? _rootDir;
  final Map<String, Profile> _profiles = {};
  Profile? _current;

  // Cache em memória do perfil atual. <1ms pra carregar, reads síncronos.
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _favorites = [];
  Map<String, Map<String, dynamic>> _progress = {};
  Map<String, dynamic>? _listsCache;

  List<Profile> get profiles => _profiles.values.toList();
  Profile? get currentProfile => _current;

  Future<void> init({Directory? rootOverride}) async {
    final docs = rootOverride ?? await getApplicationDocumentsDirectory();
    _rootDir = Directory('${docs.path}/profiles');
    if (!_rootDir!.existsSync()) _rootDir!.createSync(recursive: true);
    await _loadAllProfiles();
    await _migrateLegacyIfNeeded();
    await _resolveCurrent();
  }

  Future<void> _loadAllProfiles() async {
    _profiles.clear();
    if (_rootDir == null) return;
    for (final entry in _rootDir!.listSync()) {
      if (entry is! Directory) continue;
      final f = File('${entry.path}/profile.json');
      if (!f.existsSync()) continue;
      Profile? p;
      try {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        p = Profile.fromJson(json);
      } catch (e) {
        // I-4: tenta a última versão boa (.bak) antes de abandonar o perfil.
        final bak = File('${f.path}.bak');
        if (bak.existsSync()) {
          try {
            final json =
                jsonDecode(bak.readAsStringSync()) as Map<String, dynamic>;
            p = Profile.fromJson(json);
            debugPrint('[ProfileStore] perfil recuperado de .bak: ${entry.path}');
          } catch (_) {
            p = null;
          }
        }
        if (p == null) {
          debugPrint(
              '[ProfileStore] perfil ilegível ${entry.path} — arquivo preservado');
        }
      }
      if (p != null) _profiles[p.id] = p;
    }
  }

  Future<void> _resolveCurrent() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(_kCurrentProfileId);
    if (savedId != null && _profiles.containsKey(savedId)) {
      _current = _profiles[savedId];
    } else if (_profiles.isNotEmpty) {
      _current = _profiles.values.first;
      await prefs.setString(_kCurrentProfileId, _current!.id);
    } else {
      _current = null;
    }
    if (_current != null) await _loadCurrentCache();
  }

  Future<void> _loadCurrentCache() async {
    if (_current == null) {
      _history = [];
      _favorites = [];
      _progress = {};
      _listsCache = null;
      return;
    }
    final dir = _profileDir(_current!.id);
    _history = _readJsonList(File('${dir.path}/history.json'));
    _favorites = _readJsonList(File('${dir.path}/favorites.json'));
    _progress = _readProgressMap(File('${dir.path}/progress.json'));
    _listsCache = _readJsonMap(File('${dir.path}/lists_cache.json'));
  }

  /// I-4: leitura nunca devolve "vazio por falha de parse" de forma silenciosa.
  /// Tenta o `.bak` (última versão boa) antes de virar `[]`/`{}`, e o arquivo
  /// ilegível é **preservado em disco** (nunca sobrescrito por engano).
  List<Map<String, dynamic>> _readJsonList(File f) {
    if (!f.existsSync()) return [];
    final direct = _decodeList(f);
    if (direct != null) return direct;
    final bak = _decodeList(File('${f.path}.bak'));
    if (bak != null) return bak;
    debugPrint('[ProfileStore] lista ilegível ${f.path} — preservada, vazia');
    return [];
  }

  Map<String, Map<String, dynamic>> _readProgressMap(File f) {
    if (!f.existsSync()) return {};
    final direct = _decodeMap(f);
    if (direct != null) return direct;
    final bak = _decodeMap(File('${f.path}.bak'));
    if (bak != null) return bak;
    debugPrint('[ProfileStore] progresso ilegível ${f.path} — preservado, vazio');
    return {};
  }

  Map<String, dynamic>? _readJsonMap(File f) {
    if (!f.existsSync()) return null;
    final direct = _decodeMap(f);
    if (direct != null) return direct;
    final bak = _decodeMap(File('${f.path}.bak'));
    if (bak != null) return bak;
    debugPrint('[ProfileStore] mapa ilegível ${f.path} — preservado, nulo');
    return null;
  }

  List<Map<String, dynamic>>? _decodeList(File f) {
    if (!f.existsSync()) return null;
    try {
      final raw = f.readAsStringSync();
      if (raw.isEmpty) return [];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[ProfileStore] list read fail ${f.path}: $e');
      return null;
    }
  }

  Map<String, Map<String, dynamic>>? _decodeMap(File f) {
    if (!f.existsSync()) return null;
    try {
      final raw = f.readAsStringSync();
      if (raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded
          .map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));
    } catch (e) {
      debugPrint('[ProfileStore] map read fail ${f.path}: $e');
      return null;
    }
  }

  /// I-5: escrita atômica (temp+rename) com `.bak` da versão anterior.
  /// Um kill do processo no meio nunca deixa o arquivo principal truncado.
  Future<void> _atomicWrite(File f, String content) async {
    _atomicWriteSync(f, content);
  }

  void _atomicWriteSync(File f, String content) {
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(content, flush: true);
    if (f.existsSync()) {
      final bak = File('${f.path}.bak');
      if (bak.existsSync()) bak.deleteSync();
      f.renameSync(bak.path);
    }
    tmp.renameSync(f.path);
  }

  Future<void> _writeJsonList(File f, List<Map<String, dynamic>> list) async {
    await _atomicWrite(f, jsonEncode(list));
  }

  Future<void> _writeProgress(File f) async {
    await _atomicWrite(f, jsonEncode(_progress));
  }

  Future<void> _writeJsonMap(File f, Map<String, dynamic>? map) async {
    if (map == null) {
      if (f.existsSync()) await f.delete();
      return;
    }
    await _atomicWrite(f, jsonEncode(map));
  }

  Directory _profileDir(String id) => Directory('${_rootDir!.path}/$id');

  Profile _newProfile(String name, ProfileType type) {
    final id = _generateId();
    final dir = _profileDir(id);
    dir.createSync(recursive: true);
    final p = Profile(
      id: id,
      displayName: name,
      type: type,
      createdAt: DateTime.now(),
    );
    _atomicWriteSync(
        File('${dir.path}/profile.json'), jsonEncode(p.toJson()));
    _profiles[id] = p;
    return p;
  }

  Profile createLocalProfile(String name) {
    return _newProfile(name.trim().isEmpty ? 'Perfil' : name.trim(),
        ProfileType.local);
  }

  Future<Profile> createAnilistProfile(String token, int userId, String name,
      String? avatar) async {
    final p = _newProfile(name, ProfileType.anilist);
    final updated = p.copyWith(
      anilistToken: token,
      anilistUserId: userId,
      anilistUserName: name,
      anilistAvatar: avatar,
    );
    await _persistProfile(updated);
    _profiles[p.id] = updated;
    return updated;
  }

  Future<void> _persistProfile(Profile p) async {
    final f = File('${_profileDir(p.id).path}/profile.json');
    await _atomicWrite(f, jsonEncode(p.toJson()));
  }

  /// I-6: grava tudo do perfil atual em disco, atômico, antes de instalar
  /// uma atualização. Chamado por `UpdateService.flushData()`.
  Future<void> flush() async {
    if (_current == null) return;
    final dir = _profileDir(_current!.id);
    await _atomicWrite(
        File('${dir.path}/profile.json'), jsonEncode(_current!.toJson()));
    await _writeJsonList(File('${dir.path}/history.json'), _history);
    await _writeJsonList(File('${dir.path}/favorites.json'), _favorites);
    await _writeProgress(File('${dir.path}/progress.json'));
    await _writeJsonMap(File('${dir.path}/lists_cache.json'), _listsCache);
  }

  Future<void> deleteProfile(String id) async {
    if (!_profiles.containsKey(id)) return;
    final dir = _profileDir(id);
    if (dir.existsSync()) await dir.delete(recursive: true);
    _profiles.remove(id);
    if (_current?.id == id) {
      final prefs = await SharedPreferences.getInstance();
      if (_profiles.isNotEmpty) {
        _current = _profiles.values.first;
        await prefs.setString(_kCurrentProfileId, _current!.id);
        await _loadCurrentCache();
      } else {
        _current = null;
        await prefs.remove(_kCurrentProfileId);
        _history = [];
        _favorites = [];
        _progress = {};
        _listsCache = null;
      }
    }
  }

  Future<void> switchProfile(String id) async {
    if (!_profiles.containsKey(id)) return;
    _current = _profiles[id];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCurrentProfileId, id);
    await _loadCurrentCache();
  }

  Future<void> updateCurrentAnilist({
    String? token,
    int? userId,
    String? userName,
    String? avatar,
    bool clear = false,
  }) async {
    if (_current == null) return;
    final updated = _current!.copyWith(
      anilistToken: token,
      anilistUserId: userId,
      anilistUserName: userName,
      anilistAvatar: avatar,
      clearAnilist: clear,
    );
    _current = updated;
    _profiles[updated.id] = updated;
    await _persistProfile(updated);
  }

  // --- Dados escopados do perfil atual (síncrono = cache, async = write) ---

  List<Map<String, dynamic>> getHistory() => _history;
  Future<void> setHistory(List<Map<String, dynamic>> h) async {
    _history = h;
    if (_current == null) return;
    await _writeJsonList(File('${_profileDir(_current!.id).path}/history.json'), h);
  }

  List<Map<String, dynamic>> getFavorites() => _favorites;
  Future<void> setFavorites(List<Map<String, dynamic>> f) async {
    _favorites = f;
    if (_current == null) return;
    await _writeJsonList(
        File('${_profileDir(_current!.id).path}/favorites.json'), f);
  }

  Map<String, dynamic>? getProgress(String animeKey) => _progress[animeKey];
  Map<String, Map<String, dynamic>> getAllProgress() =>
      Map.unmodifiable(_progress);
  Future<void> setProgress(String animeKey, Map<String, dynamic> data) async {
    _progress[animeKey] = data;
    if (_current == null) return;
    await _writeProgress(File('${_profileDir(_current!.id).path}/progress.json'));
  }

  Map<String, dynamic>? getListsCache() => _listsCache;
  Future<void> setListsCache(Map<String, dynamic>? data) async {
    _listsCache = data;
    if (_current == null) return;
    await _writeJsonMap(
        File('${_profileDir(_current!.id).path}/lists_cache.json'), data);
  }

  // --- Migração de dados legados do SharedPreferences ---

  Future<void> _migrateLegacyIfNeeded() async {
    if (_profiles.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final hasLegacy = keys.contains('anilist_token') ||
        keys.contains('history') ||
        keys.contains('favorites') ||
        keys.any((k) => k.startsWith('progress_'));
    if (!hasLegacy) return;

    debugPrint('[ProfileStore] migrating legacy data...');
    final token = prefs.getString('anilist_token');
    final userJsonStr = prefs.getString('anilist_user');
    String name = 'Perfil';
    int? anilistId;
    String? anilistName, anilistAvatar;
    if (userJsonStr != null) {
      try {
        final u = jsonDecode(userJsonStr) as Map<String, dynamic>;
        anilistId = u['id'] as int?;
        anilistName = u['name'] as String?;
        anilistAvatar = u['avatar'] as String?;
        if (anilistName != null && anilistName.isNotEmpty) name = anilistName;
      } catch (_) {}
    }

    final profile = _newProfile(
      name,
      token != null ? ProfileType.anilist : ProfileType.local,
    );
    final updated = profile.copyWith(
      anilistToken: token,
      anilistUserId: anilistId,
      anilistUserName: anilistName,
      anilistAvatar: anilistAvatar,
    );
    await _persistProfile(updated);
    _profiles[profile.id] = updated;

    final dir = _profileDir(profile.id);

    final listsCacheStr = prefs.getString('anilist_lists_cache');
    if (listsCacheStr != null && listsCacheStr.isNotEmpty) {
      try {
        final listsJson = jsonDecode(listsCacheStr) as Map<String, dynamic>;
        await _atomicWrite(
            File('${dir.path}/lists_cache.json'), jsonEncode(listsJson));
      } catch (e) {
        debugPrint('[ProfileStore] lists_cache migrate fail: $e');
      }
    }

    final historyStr = prefs.getString('history');
    if (historyStr != null && historyStr.isNotEmpty) {
      try {
        final list = (jsonDecode(historyStr) as List).cast<Map<String, dynamic>>();
        await _atomicWrite(
            File('${dir.path}/history.json'), jsonEncode(list));
      } catch (e) {
        debugPrint('[ProfileStore] history migrate fail: $e');
      }
    }

    final favoritesStr = prefs.getString('favorites');
    if (favoritesStr != null && favoritesStr.isNotEmpty) {
      try {
        final list =
            (jsonDecode(favoritesStr) as List).cast<Map<String, dynamic>>();
        await _atomicWrite(
            File('${dir.path}/favorites.json'), jsonEncode(list));
      } catch (e) {
        debugPrint('[ProfileStore] favorites migrate fail: $e');
      }
    }

    final progressMap = <String, dynamic>{};
    for (final k in keys.where((k) => k.startsWith('progress_'))) {
      final v = prefs.getString(k);
      if (v == null || v.isEmpty) continue;
      try {
        progressMap[k.substring('progress_'.length)] = jsonDecode(v);
      } catch (_) {}
    }
    if (progressMap.isNotEmpty) {
      await _atomicWrite(
          File('${dir.path}/progress.json'), jsonEncode(progressMap));
    }

    await prefs.remove('anilist_token');
    await prefs.remove('anilist_user');
    await prefs.remove('anilist_lists_cache');
    await prefs.remove('history');
    await prefs.remove('favorites');
    for (final k in keys.where((k) => k.startsWith('progress_'))) {
      await prefs.remove(k);
    }

    await prefs.setString(_kCurrentProfileId, profile.id);
    _current = updated;
    await _loadCurrentCache();
    debugPrint('[ProfileStore] migration complete: profile=${profile.id}');
  }

  // ponytail: ms timestamp + 4 hex random = unique enough for local profile IDs.
  // Colisão só se 2 perfis criados no mesmo ms com mesmo random (1:65536).
  String _generateId() {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rnd = Random().nextInt(0xffff).toRadixString(36).padLeft(3, '0');
    return '${ts}_$rnd';
  }

  @visibleForTesting
  void resetForTest() {
    _rootDir = null;
    _profiles.clear();
    _current = null;
    _history = [];
    _favorites = [];
    _progress = {};
    _listsCache = null;
  }
}
