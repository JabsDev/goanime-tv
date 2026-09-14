import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Cache em disco das legendas IA com TTL fixo de 5 dias (plano §TTL).
///
/// - Local: `appSupport/subs/{animeKey}/ep{N}.{srcLang}-{mt}.srt` + `.meta.json`.
/// - Validade FIXA desde `createdAt`; acesso NÃO renova.
/// - `get` expirado deleta os arquivos e retorna null.
/// - `pruneExpired` varre só `subs/` (sem isolate).
/// - `clock` injetável p/ teste com mock de tempo.
// ignore: avoid_classes_with_only_static_members
class SubtitleStore {
  /// Constante única: mudar aqui muda tudo.
  static const kSrtTtl = Duration(days: 5);

  static const _prunePrefsKey = 'subs_last_prune_ms';

  static DateTime Function()? _clockForTest;

  /// @visibleForTesting
  static void setClockForTest(DateTime Function()? fn) => _clockForTest = fn;

  static DateTime _now() =>
      _clockForTest != null ? _clockForTest!() : DateTime.now();

  static String sanitizeKey(String k) =>
      k.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_').substring(
          0, k.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_').length.clamp(0, 80));

  static Future<Directory> _subsDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/subs');
  }

  static File _srtFile(Directory subs, String animeKey, int ep, String tag) =>
      File('${subs.path}/${sanitizeKey(animeKey)}/ep$ep.$tag.srt');

  static File _metaFile(File srt) => File('${srt.path}.meta.json');

  /// Salva `.srt` + sidecar `.meta.json{createdAt,srcHash}`.
  static Future<File> put({
    required String animeKey,
    required int ep,
    required String tag,
    required String srt,
    required String srcHash,
    Directory? subsDirForTest,
  }) async {
    final subs = subsDirForTest ?? await _subsDir();
    final f = _srtFile(subs, animeKey, ep, tag);
    await f.parent.create(recursive: true);
    await f.writeAsString(srt);
    await _metaFile(f).writeAsString(jsonEncode({
      'createdAt': _now().millisecondsSinceEpoch,
      'srcHash': srcHash,
    }));
    return f;
  }

  /// Retorna o arquivo se válido; null (e deleta) se expirado/ausente.
  /// Queda de `srcHash` (fonte mudou) também invalida.
  static Future<File?> get({
    required String animeKey,
    required int ep,
    required String tag,
    String? srcHash,
    Directory? subsDirForTest,
  }) async {
    final subs = subsDirForTest ?? await _subsDir();
    final f = _srtFile(subs, animeKey, ep, tag);
    final meta = _metaFile(f);
    if (!await f.exists() || !await meta.exists()) return null;
    try {
      final m = jsonDecode(await meta.readAsString()) as Map;
      final created =
          DateTime.fromMillisecondsSinceEpoch((m['createdAt'] as num).toInt());
      if (_now().difference(created) > kSrtTtl) {
        await _deletePair(f, meta); // ponytail: mtime do .meta, sem DB novo
        return null;
      }
      if (srcHash != null && m['srcHash'] != srcHash) {
        await _deletePair(f, meta);
        return null;
      }
      return f;
    } catch (_) {
      await _deletePair(f, meta);
      return null;
    }
  }

  static Future<void> _deletePair(File srt, File meta) async {
    try {
      await srt.delete();
    } catch (_) {}
    try {
      await meta.delete();
    } catch (_) {}
  }

  /// Remove só expirados dentro de `subs/`. Chamada em main() pós-init,
  /// ao completar job e ao abrir Detail (throttle 24h via prefs).
  static Future<int> pruneExpired({Directory? subsDirForTest}) async {
    final subs = subsDirForTest ?? await _subsDir();
    if (!await subs.exists()) return 0;
    var removed = 0;
    await for (final animeDir in subs.list()) {
      if (animeDir is! Directory) continue;
      await for (final e in animeDir.list()) {
        if (e is! File || !e.path.endsWith('.srt')) continue;
        final meta = File('${e.path}.meta.json');
        var expired = true;
        try {
          if (await meta.exists()) {
            final m = jsonDecode(await meta.readAsString()) as Map;
            final created = DateTime.fromMillisecondsSinceEpoch(
                (m['createdAt'] as num).toInt());
            expired = _now().difference(created) > kSrtTtl;
          }
        } catch (_) {
          expired = true;
        }
        if (expired) {
          await _deletePair(e, meta);
          removed++;
        }
      }
    }
    return removed;
  }

  /// Espaço usado pelas legendas IA (Settings).
  static Future<int> usedBytes({Directory? subsDirForTest}) async {
    final subs = subsDirForTest ?? await _subsDir();
    if (!await subs.exists()) return 0;
    var total = 0;
    await for (final e in subs.list(recursive: true)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  static Future<void> clearAll({Directory? subsDirForTest}) async {
    final subs = subsDirForTest ?? await _subsDir();
    if (await subs.exists()) await subs.delete(recursive: true);
  }

  static String sha256Of(String s) => sha256.convert(utf8.encode(s)).toString();

  static String get prunePrefsKey => _prunePrefsKey;
}
