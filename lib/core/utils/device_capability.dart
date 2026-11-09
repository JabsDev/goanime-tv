import 'dart:io';

import 'package:flutter/foundation.dart';

import '../device/device_benchmark.dart';
import '../device/device_hardware.dart';
import '../device/device_profile.dart';

/// Detecção de aparelho fraco + perfil de potência.
///
/// Histórico: a primeira versão olhava só `MemAvailable < 1500 MB` e por isso
/// tratava um Fire Stick (A53 @1,7 GHz) e um projetor H713 (A53 @1,3 GHz) como
/// iguais — ambos têm 1 GB. Agora o perfil soma CPU (núcleos, clock, ABI,
/// NEON), RAM e decoders de hardware; o benchmark opcional refina o resultado.
///
/// `isLowEnd()` continua significando "pouca RAM" (modo lite de UI e gate dos
/// modelos de legenda IA). O teto de qualidade usa `assessment.tier`, que é
/// mais fino: um aparelho pode ficar em modo lite e ainda tocar 720p.
class DeviceCapability {
  DeviceCapability._();

  /// Fallback legado (Linux/Android sem o canal nativo).
  static const int _lowMemKb = 1500 * 1024;

  /// Heurística de RAM do modo lite. Abaixo disso o Flutter + player sofrem
  /// com o cache de imagens e buffers do mpv/ExoPlayer.
  static const int _lowAvailableRamMb = 1500;

  static DeviceProfile? _profile;
  static DeviceAssessment? _assessment;
  static BenchmarkSnapshot? _benchmark;
  static bool? _lowEnd;
  static Future<DeviceAssessment>? _pending;

  static DeviceProfile? get profile => _profile;
  static BenchmarkSnapshot? get benchmark => _benchmark;

  /// Sem perfil (desktop/teste) devolve [DeviceAssessment.unknown] — nunca
  /// derruba a experiência completa por falta de informação.
  static DeviceAssessment get assessment =>
      _assessment ?? DeviceAssessment.unknown;

  /// Coleta o perfil uma vez. [refresh] relê o nativo (ex.: depois de um
  /// benchmark, ver mudança de memória livre).
  static Future<DeviceAssessment> load({bool refresh = false}) {
    if (!refresh) {
      final cached = _assessment;
      if (cached != null) return Future.value(cached);
    }
    final pending = _pending;
    if (!refresh && pending != null) return pending;
    _pending = _load();
    return _pending!;
  }

  static Future<DeviceAssessment> _load() async {
    Map<String, dynamic>? raw;
    try {
      // Sem guard de plataforma: em desktop/teste o canal não existe e cai no
      // MissingPluginException (perfil null, avaliação "capaz"). Isso também
      // deixa o caminho testável com um mock de MethodChannel.
      raw = await DeviceHardware.readProfile();
    } catch (e) {
      debugPrint('[DeviceCapability] perfil nativo falhou: $e');
    }

    final profile = raw == null ? null : DeviceProfile.fromMap(raw);
    final benchmark = await DeviceBenchmarkStore.read();

    _profile = profile;
    _benchmark = benchmark;
    _lowEnd = null; // recalcula com o perfil novo
    _assessment = profile == null
        ? DeviceAssessment.unknown
        : assessDevice(profile, benchmarkScore: benchmark?.score);

    debugPrint(
      '[DeviceCapability] ${profile?.model ?? 'perfil indisponível'} → '
      '${_assessment!.tier.name} (${_assessment!.score}) '
      'freq=${profile?.cpuMaxFreqMhz} cores=${profile?.cores} '
      'ram=${profile?.totalRamMb}/${profile?.availableRamMb} '
      'bench=${benchmark?.score.toStringAsFixed(0) ?? '-'}',
    );
    return _assessment!;
  }

  /// Grava o benchmark e reavalia na hora. Retorna a avaliação nova.
  static Future<DeviceAssessment> applyBenchmark(
    DeviceBenchmarkResult result,
  ) async {
    final snap = await DeviceBenchmarkStore.save(result);
    _benchmark = snap;
    final p = _profile;
    _assessment = p == null
        ? DeviceAssessment.unknown
        : assessDevice(p, benchmarkScore: snap.score);
    debugPrint(
      '[DeviceCapability] benchmark ${result.detectionScore}/100 → '
      '${_assessment!.tier.name} (${_assessment!.score})',
    );
    return _assessment!;
  }

  /// True se o aparelho tem pouca RAM (gatilho do modo lite/legenda IA).
  ///
  /// Conservador: erro → NÃO fraco. O perfil nativo manda quando existe;
  /// o `/proc/meminfo` continua como fallback (Linux/desktop/testes).
  static Future<bool> isLowEnd() async {
    final cached = _lowEnd;
    if (cached != null) return cached;

    if (_assessment == null) await load();
    final p = _profile;
    if (p != null) {
      final avail = p.availableRamMb > 0 ? p.availableRamMb : p.totalRamMb;
      if (avail > 0) {
        _lowEnd = avail < _lowAvailableRamMb || p.lowRamDevice;
        return _lowEnd!;
      }
    }
    _lowEnd = await _legacyLowMem();
    return _lowEnd!;
  }

  static Future<bool> _legacyLowMem() async {
    if (!Platform.isAndroid && !Platform.isLinux) return false;
    try {
      final result = await Process.run('cat', ['/proc/meminfo']);
      if (result.exitCode != 0) return false;
      final m = RegExp(r'MemAvailable:\s+(\d+) kB').firstMatch(result.stdout);
      if (m == null) return false;
      return int.parse(m.group(1)!) < _lowMemKb;
    } catch (e) {
      debugPrint('[DeviceCapability] detect error: $e');
      return false;
    }
  }

  @visibleForTesting
  static void resetCache() {
    _profile = null;
    _assessment = null;
    _benchmark = null;
    _lowEnd = null;
    _pending = null;
  }

  /// Injeta uma avaliação pronta (testes de UI/wiring do teto de qualidade).
  @visibleForTesting
  static void debugSetAssessment(
    DeviceAssessment assessment, {
    DeviceProfile? profile,
    BenchmarkSnapshot? benchmark,
  }) {
    _assessment = assessment;
    _profile = profile;
    _benchmark = benchmark;
    _lowEnd = null;
    _pending = null;
  }
}
