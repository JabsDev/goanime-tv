import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../profile/profile_store.dart';
import '../utils/text_utils.dart';

class LocalStorage {
  static SharedPreferences? _prefs;

  /// B1: normaliza a chave pública (nome do anime) para que favoritos/
  /// histórico/progresso salvos sob um título velho sujo (com nota/faixa)
  /// continuem "casando" com o nome limpo do scraper.
  static String _normalizeKey(String key) => TextUtils.cleanTitle(key.trim());

  /// Procura o progresso cuja chave NORMALIZADA casa com [key], tolerando
  /// chaves legadas ainda gravadas com título sujo.
  static Map<String, dynamic>? _findProgress(String key) {
    final entries = ProfileStore.instance.getAllProgress().entries;
    for (final e in entries) {
      if (_normalizeKey(e.key) == key) return e.value;
    }
    return null;
  }

  /// Lê o mapa de retomada por episódio (`positions`: "índice" → milissegundos).
  /// O high-water `episode`/`position` continua sendo o last-played; a retomada
  /// fina de cada ep vive aqui, independente do estado `watched`.
  static Map<int, int> _readPositions(Map<String, dynamic>? progress) {
    final raw = progress?['positions'] as Map? ?? const {};
    final out = <int, int>{};
    for (final e in raw.entries) {
      final idx = int.tryParse(e.key.toString());
      final ms = e.value is int
          ? e.value as int
          : int.tryParse(e.value.toString());
      if (idx != null && ms != null) out[idx] = ms;
    }
    return out;
  }

  /// Normaliza os títulos guardados (chave + título) para exibição, de modo
  /// que entradas legadas ainda mostrem o nome limpo.
  static List<Map<String, dynamic>> _normalizedEntries(
      List<Map<String, dynamic>> list) {
    return list.map((e) {
      final title = e['title']?.toString() ?? '';
      final clean = TextUtils.cleanTitle(title);
      if (clean == title) return e;
      return {...e, 'title': clean};
    }).toList();
  }

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

  /// BUGFIX (75%): este método NÃO marca assistido — só persiste o last-played
  /// (`episode`/`position`) e a retomada fina por episódio (`positions`). Antes
  /// o high-water `episode`, gravado já nos primeiros segundos, era usado pelo
  /// grid como evidência de "assistido", fazendo abrir-e-sair deixar 0..N verdes
  /// (e permitindo back-push falso ao AniList). "Assistido" agora vem só do
  /// conjunto `watched` (gate de 75% em markEpisodeWatched / reconcileWatched).
  static Future<void> saveWatchProgress({
    required String animeKey,
    required int episodeNumber,
    required Duration position,
    required int totalEpisodes,
  }) async {
    ensureInitialized();
    final key = _normalizeKey(animeKey);
    // ponytail: preserva conjunto 'watched' e mapa 'positions' ao reescrever
    // progress. Antes o overwrite incondicional descartava todos os eps já
    // marcados — fatal para fluxos não-contíguos (ex.: assistir 1-8 e 12).
    final existing = _findProgress(key);
    final watched = (existing?['watched'] as List?)?.cast<int>().toList() ??
        const <int>[];
    final positions = _readPositions(existing);
    positions[episodeNumber] = position.inMilliseconds;
    await ProfileStore.instance.setProgress(key, {
      'episode': episodeNumber,
      'position': position.inMilliseconds,
      'totalEpisodes': totalEpisodes,
      'watched': watched,
      'positions': {
        for (final e in positions.entries) '${e.key}': e.value,
      },
    });
  }

  static Map<String, dynamic>? getWatchProgress(String animeKey) {
    ensureInitialized();
    return _findProgress(_normalizeKey(animeKey));
  }

  /// Mapa de retomada por episódio (índice → ms) do anime, para o grid exibir
  /// onde cada ep parou. Vazio quando nada foi assistido pela metade.
  static Map<int, int> getResumePositions(String animeKey) {
    ensureInitialized();
    return _readPositions(_findProgress(_normalizeKey(animeKey)));
  }

  /// Posição salva de retomada do episódio [episodeIndex]. Lê do mapa
  /// `positions`; fallback legado para o `position` único quando ele pertence
  /// ao mesmo ep (schema antigo, um único last-played).
  static Duration? getResumePosition(String animeKey, int episodeIndex) {
    ensureInitialized();
    final progress = _findProgress(_normalizeKey(animeKey));
    final positions = _readPositions(progress);
    final ms = positions[episodeIndex];
    if (ms != null) return Duration(milliseconds: ms);
    if ((progress?['episode'] as int?) == episodeIndex) {
      final pos = progress?['position'] as int?;
      if (pos != null) return Duration(milliseconds: pos);
    }
    return null;
  }

  // Marca um episódio como assistido no conjunto do perfil atual.
  // Totalmente idempotente: re-marcar um índice existente não cresce a lista
  // nem reescreve o disco (toSet().add + early-return).
  // Gate único de "assistido": chamado pelo player ao cruzar 75% do ep (e por
  // reconcileWatched via progresso AniList). Ao marcar, remove a retomada
  // (positions/position) do ep — assistido não mostra mais badge de retomada.
  static Future<void> markEpisodeWatched({
    required String animeKey,
    required int episodeIndex,
  }) async {
    ensureInitialized();
    final key = _normalizeKey(animeKey);
    final existing = _findProgress(key) ?? <String, dynamic>{};
    final watched =
        ((existing['watched'] as List?)?.cast<int>() ?? const <int>[]).toSet();
    if (!watched.add(episodeIndex)) return;
    existing['watched'] = watched.toList();
    final positions = _readPositions(existing);
    positions.remove(episodeIndex);
    existing['positions'] = {
      for (final e in positions.entries) '${e.key}': e.value,
    };
    if (existing['episode'] == episodeIndex) {
      existing.remove('position');
    }
    await ProfileStore.instance.setProgress(key, existing);
  }

  /// Casa o conjunto assistido local com um progresso N (vindo do AniList ou
  /// do high-water-mark local), marcando CONTÍGUO 0..N-1. Honra a regra
  /// "último assistido = N ⇒ marca 1..N" (Q4) e AniList como fonte de verdade
  /// cross-device (Q5). Idempotente: nada a fazer se o conjunto já cobre.
  /// Preserva position/episode existentes; só avança episode se N-1 > atual.
  /// Não DESCASCA nada — só adiciona (max-merge p/ não perder progresso).
  static Future<void> reconcileWatched({
    required String animeKey,
    required int progress,
  }) async {
    if (progress <= 0) return;
    ensureInitialized();
    final key = _normalizeKey(animeKey);
    final existing = _findProgress(key) ?? <String, dynamic>{};
    final watched =
        ((existing['watched'] as List?)?.cast<int>() ?? const <int>[]).toSet();
    final target = <int>{for (var i = 0; i < progress; i++) i};
    final newEp = progress - 1;
    final ep = existing['episode'] as int? ?? -1;
    if (watched.containsAll(target)) {
      // já coberto — só alinha high-water-mark se trás avanço
      if (newEp <= ep) return;
      existing['episode'] = newEp;
      await ProfileStore.instance.setProgress(key, existing);
      return;
    }
    watched.addAll(target);
    existing['watched'] = watched.toList()..sort();
    if (newEp > ep) existing['episode'] = newEp;
    await ProfileStore.instance.setProgress(key, existing);
  }

  static Future<void> addToHistory({
    required String animeKey,
    required String title,
    required String imageUrl,
    required int lastEpisode,
    required int totalEpisodes,
    int? anilistId,
  }) async {
    ensureInitialized();
    final key = _normalizeKey(animeKey);
    final history = getHistory();
    history.removeWhere(
        (e) => _normalizeKey(e['key']?.toString() ?? '') == key);
    history.insert(0, {
      'key': key,
      'title': TextUtils.cleanTitle(title),
      'image': imageUrl,
      'lastEpisode': lastEpisode,
      'totalEpisodes': totalEpisodes,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      if (anilistId != null) 'anilistId': anilistId,
    });
    if (history.length > 50) history.removeRange(50, history.length);
    await ProfileStore.instance.setHistory(history);
  }

  static List<Map<String, dynamic>> getHistory() {
    ensureInitialized();
    return _normalizedEntries(ProfileStore.instance.getHistory());
  }

  static Future<void> toggleFavorite({
    required String animeKey,
    required String title,
    required String imageUrl,
    int? anilistId,
  }) async {
    ensureInitialized();
    final key = _normalizeKey(animeKey);
    final favorites = getFavorites();
    final idx = favorites
        .indexWhere((e) => _normalizeKey(e['key']?.toString() ?? '') == key);
    if (idx >= 0) {
      favorites.removeAt(idx);
    } else {
      favorites.add({
        'key': key,
        'title': TextUtils.cleanTitle(title),
        'image': imageUrl,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
    'anilistId': anilistId,
      });
    }
    await ProfileStore.instance.setFavorites(favorites);
  }

  static List<Map<String, dynamic>> getFavorites() {
    ensureInitialized();
    return _normalizedEntries(ProfileStore.instance.getFavorites());
  }

  static bool isFavorite(String animeKey) {
    final key = _normalizeKey(animeKey);
    return getFavorites()
        .any((e) => _normalizeKey(e['key']?.toString() ?? '') == key);
  }
}
