import 'dart:io';

import 'package:flutter/foundation.dart';

/// Detecção lazy de dispositivo fraco sem dependência nova.
/// ponytail: lê `/proc/meminfo` em Android/Linux (kernel expõe MemAvailable).
/// Não adiciona `device_info_plus` por algo que 5 linhas resolvem.
class DeviceCapability {
  /// Heap-alvo (TV stick 1GB total geralmente tem <1500MB livre).
  static const int _lowMemKb = 1500 * 1024;

  static bool? _cached;

  /// True se o dispositivo provavelmente roda em modo fraco.
  /// Conservador: em caso de erro assume NÃO fraco (mantém experiência completa).
  static Future<bool> isLowEnd() async {
    if (_cached != null) return _cached!;
    if (!Platform.isAndroid && !Platform.isLinux) {
      _cached = false;
      return false;
    }
    try {
      final result = await Process.run('cat', ['/proc/meminfo']);
      if (result.exitCode != 0) {
        _cached = false;
        return false;
      }
      final m = RegExp(r'MemAvailable:\s+(\d+) kB').firstMatch(result.stdout);
      if (m == null) {
        _cached = false;
        return false;
      }
      final kb = int.parse(m.group(1)!);
      _cached = kb < _lowMemKb;
      return _cached!;
    } catch (e) {
      debugPrint('[DeviceCapability] detect error: $e');
      _cached = false;
      return false;
    }
  }
}