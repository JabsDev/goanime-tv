import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../cache/app_caches.dart';
import 'aniskip_models.dart';

class AniskipService {
  static const _base = 'https://api.aniskip.com';

  /// Test hook como AniListService.httpOverride
  static http.Client? httpOverride;

  static http.Client get _client => httpOverride ?? http.Client();

  /// Converte duração em episodeLength para AniSkip (preciso).
  /// videoReady + playerDurationSec tem prioridade (ms preciso), fallback AniList minutes*60, fallback 0.
  static double episodeLengthFor({
    required int? anilistDurationMin,
    required double playerDurationSec,
    required bool videoReady,
  }) {
    if (videoReady && playerDurationSec >= 10) {
      return double.parse(playerDurationSec.toStringAsFixed(2));
    }
    if (anilistDurationMin != null && anilistDurationMin > 0) {
      return (anilistDurationMin * 60).toDouble();
    }
    return 0;
  }

  /// Aplica relation-rules de MAL (ex. One Piece 1-220 -> 1735).
  static ({int malId, int episode}) applyRules(
      int malId, int episode, List<RelationRule> rules) {
    for (final r in rules) {
      if (r.contains(episode)) {
        return (malId: r.toMalId, episode: r.mapEpisode(episode));
      }
    }
    return (malId: malId, episode: episode);
  }

  static Future<List<RelationRule>> getRelationRules(int malId) async {
    final cacheKey = 'aniskip_rules:$malId';
    final cached = AppCaches.skip.get<List<RelationRule>>(cacheKey);
    if (cached != null) return cached;
    try {
      final uri = Uri.parse('$_base/v2/relation-rules/$malId');
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['found'] != true) return [];
      final list = (json['rules'] as List? ?? []);
      final rules = <RelationRule>[];
      for (final r in list) {
        final from = r['from'] as Map? ?? {};
        final to = r['to'] as Map? ?? {};
        rules.add(RelationRule(
          fromStart: from['start'] as int? ?? 0,
          fromEnd: from['end'] as int? ?? 0,
          toMalId: to['malId'] as int? ?? malId,
          toStart: to['start'] as int? ?? 0,
          toEnd: to['end'] as int? ?? 0,
        ));
      }
      AppCaches.skip.set(cacheKey, rules, ttl: const Duration(hours: 24));
      return rules;
    } catch (e) {
      debugPrint('[Aniskip] rules error: $e');
      return [];
    }
  }

  static String _skipCacheKey(int malId, int ep, double len) =>
      'aniskip:$malId:$ep:${len.round()}';
  static String _skipDiskKey(int malId, int ep, double len) =>
      'skip_v2_${malId}_${ep}_${len.round()}';

  static Future<SkipResult> getSkipTimes({
    required int malId,
    required int episode,
    double episodeLength = 0,
    List<String> types = const ['op', 'ed', 'mixed-op', 'mixed-ed', 'recap'],
  }) async {
    // aplica rules antes
    final rules = await getRelationRules(malId);
    final mapped = applyRules(malId, episode, rules);
    final mId = mapped.malId;
    final mEp = mapped.episode;

    final key = _skipCacheKey(mId, mEp, episodeLength);
    final cached = AppCaches.skip.get<SkipResult>(key);
    if (cached != null) {
      if (!cached.found && episodeLength != 0) {
        // 404 com length específico pode ser falso-negativo por tolerância;
        // tenta 0 (sem filtro) antes de desistir.
        final fallback = await getSkipTimes(
            malId: mId, episode: mEp, episodeLength: 0, types: types);
        if (fallback.found) return fallback;
      }
      return cached;
    }

    // disk fallback
    final disk = await _readDisk(mId, mEp, episodeLength);
    // tenta rede, mas se offline retorna disk
    try {
      final typesQuery = types.map((t) => 'types[]=$t').join('&');
      final uri = Uri.parse(
          '$_base/v2/skip-times/$mId/$mEp?episodeLength=$episodeLength${typesQuery.isEmpty ? '' : '&$typesQuery'}');
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 404) {
        // AniSkip 404 = found:false — tenta fallback 0 se len !=0
        if (episodeLength != 0) {
          debugPrint('[Aniskip] 404 with len $episodeLength, retry 0');
          final fallback = await getSkipTimes(
              malId: mId, episode: mEp, episodeLength: 0, types: types);
          if (fallback.found) {
            AppCaches.skip.set(key, fallback, ttl: const Duration(hours: 6));
            return fallback;
          }
        }
        try {
          final j = jsonDecode(res.body) as Map<String, dynamic>;
          if (j['found'] == false) {
            const r = SkipResult(found: false, intervals: []);
            AppCaches.skip.set(key, r, ttl: const Duration(days: 1));
            return r;
          }
        } catch (_) {}
        const r = SkipResult(found: false, intervals: []);
        AppCaches.skip.set(key, r, ttl: const Duration(hours: 6));
        return disk ?? r;
      }
      if (res.statusCode != 200) {
        debugPrint('[Aniskip] skip-times ${res.statusCode}: ${res.body}');
        return disk ?? const SkipResult(found: false, intervals: []);
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['found'] != true) {
        if (episodeLength != 0) {
          final fallback = await getSkipTimes(
              malId: mId, episode: mEp, episodeLength: 0, types: types);
          if (fallback.found) return fallback;
        }
        const r = SkipResult(found: false, intervals: []);
        AppCaches.skip.set(key, r, ttl: const Duration(days: 1));
        await _writeDisk(mId, mEp, episodeLength, r);
        return r;
      }
      final list = (json['results'] as List? ?? []);
      final intervals = <SkipInterval>[];
      for (final e in list) {
        final interval = e['interval'] as Map? ?? {};
        final start = (interval['startTime'] as num?)?.toDouble();
        final end = (interval['endTime'] as num?)?.toDouble();
        if (start == null || end == null) continue;
        if (start >= end) continue;
        if (end < 5) continue;
        intervals.add(SkipInterval(
          skipType: e['skipType']?.toString() ?? 'op',
          start: start,
          end: end,
          skipId: e['skipId']?.toString() ?? '',
          episodeLength: (e['episodeLength'] as num?)?.toDouble() ?? episodeLength,
        ));
      }
      final result = SkipResult(found: true, intervals: intervals);
      AppCaches.skip.set(key, result, ttl: const Duration(days: 7));
      await _writeDisk(mId, mEp, episodeLength, result);
      return result;
    } catch (e) {
      debugPrint('[Aniskip] getSkipTimes error: $e');
      return disk ?? const SkipResult(found: false, intervals: []);
    }
  }

  static Future<SkipResult?> _readDisk(int malId, int ep, double len) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_skipDiskKey(malId, ep, len));
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final list = (j['intervals'] as List? ?? []);
      final intervals = list.map((e) {
        final m = e as Map<String, dynamic>;
        return SkipInterval(
          skipType: m['skipType']?.toString() ?? 'op',
          start: (m['start'] as num).toDouble(),
          end: (m['end'] as num).toDouble(),
          skipId: m['skipId']?.toString() ?? '',
          episodeLength: (m['episodeLength'] as num).toDouble(),
        );
      }).toList();
      return SkipResult(found: j['found'] as bool? ?? true, intervals: intervals);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeDisk(int malId, int ep, double len, SkipResult r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _skipDiskKey(malId, ep, len),
        jsonEncode({
          'found': r.found,
          'intervals': r.intervals
              .map((e) => {
                    'skipType': e.skipType,
                    'start': e.start,
                    'end': e.end,
                    'skipId': e.skipId,
                    'episodeLength': e.episodeLength,
                  })
              .toList(),
        }),
      );
    } catch (_) {}
  }
}
