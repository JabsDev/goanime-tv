import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Benchmark rápido de CPU/RAM (~0,6 s) para calibrar a detecção de hardware.
///
/// Não tenta prever fps de vídeo: mede três coisas que, juntas, separam bem um
/// A53 de 1,3 GHz de um de 1,7 GHz — inteiros, ponto flutuante e banda de
/// memória (o decode em software depende dos três). O resultado vira um
/// índice 0–100 que entra no `assessDevice` como substituição/ajuste.
///
/// Os limiares de normalização são **calibráveis**: a tela de diagnóstico
/// mostra os valores crus para ajustar [intZero]/[intFull] etc. com aparelhos
/// reais, sem precisar adivinhar por benchmark de celular.
class DeviceBenchmark {
  DeviceBenchmark._();

  /// Muda quando a fórmula muda; resultado antigo é ignorado.
  static const int version = 1;

  static const Duration defaultSample = Duration(milliseconds: 180);

  /// Roda em isolate próprio: a UI continua respondendo ao D-pad.
  static Future<DeviceBenchmarkResult> run({Duration sample = defaultSample}) {
    return Isolate.run(() => runSync(sample: sample));
  }

  /// Versão síncrona (testes/uso embarcado). Aquece uma vez e mede por
  /// [sample] em cada carga; repetir mantém a medição estável em CPU rápida.
  @visibleForTesting
  static DeviceBenchmarkResult runSync({Duration sample = defaultSample}) {
    final sw = Stopwatch()..start();
    final intMops = _intThroughput(sample);
    final floatMops = _floatThroughput(sample);
    final memMibps = _memThroughput(sample);
    sw.stop();
    return DeviceBenchmarkResult(
      intMops: intMops,
      floatMops: floatMops,
      memMibps: memMibps,
      score: benchmarkScore(intMops, floatMops, memMibps),
      elapsed: sw.elapsed,
    );
  }

  // Limiares de normalização (valor que zera / valor que satura).
  static const double intZero = 4;
  static const double intFull = 40;
  static const double floatZero = 4;
  static const double floatFull = 40;
  static const double memZero = 300;
  static const double memFull = 2500;

  /// Índice 0–100: inteiros 45%, float 25%, cópia de memória 30%.
  @visibleForTesting
  static double benchmarkScore(
    double intMops,
    double floatMops,
    double memMibps,
  ) {
    final i = _norm(intMops, intZero, intFull);
    final f = _norm(floatMops, floatZero, floatFull);
    final m = _norm(memMibps, memZero, memFull);
    return (i * 0.45 + f * 0.25 + m * 0.30).clamp(0.0, 100.0);
  }

  static double _norm(double v, double zero, double full) =>
      ((v - zero) / (full - zero)).clamp(0.0, 1.0) * 100;

  // Sinks observáveis: impedem o AOT de eliminar o laço como código morto.
  @visibleForTesting
  static int intSink = 0;
  @visibleForTesting
  static double floatSink = 0;
  @visibleForTesting
  static int byteSink = 0;

  @visibleForTesting
  static double runIntFor(Duration sample) => _intThroughput(sample);

  @visibleForTesting
  static double runFloatFor(Duration sample) => _floatThroughput(sample);

  @visibleForTesting
  static double runMemoryFor(Duration sample) => _memThroughput(sample);

  static double _intThroughput(Duration sample) {
    const batch = 200000;
    var x = 0x9e3779b9;
    var acc = 0;
    void work(int n) {
      var local = x;
      var localAcc = acc;
      for (var i = 0; i < n; i++) {
        local ^= (local << 13) & 0xffffffff;
        local ^= local >>> 17;
        local ^= (local << 5) & 0xffffffff;
        localAcc = (localAcc + (local & 0xffff)) & 0x7fffffff;
      }
      x = local;
      acc = localAcc;
    }

    work(batch ~/ 4); // aquecimento (JIT/AOT/caches)
    var iterations = 0;
    final sw = Stopwatch()..start();
    do {
      work(batch);
      iterations += batch;
    } while (sw.elapsed < sample);
    final seconds = sw.elapsedMicroseconds / 1e6;
    intSink = acc;
    if (seconds <= 0) return 0;
    return iterations / seconds / 1e6;
  }

  static double _floatThroughput(Duration sample) {
    const batch = 100000;
    final buf = Float64List(128);
    for (var i = 0; i < buf.length; i++) {
      buf[i] = i * 0.5;
    }
    var acc = 0.0;
    void work(int n) {
      var local = acc;
      for (var i = 0; i < n; i++) {
        final j = i & 127;
        final v = buf[j] * 1.000001 + 0.0000001;
        buf[j] = v;
        local += v;
      }
      acc = local;
    }

    work(batch ~/ 4);
    var iterations = 0;
    final sw = Stopwatch()..start();
    do {
      work(batch);
      iterations += batch;
    } while (sw.elapsed < sample);
    final seconds = sw.elapsedMicroseconds / 1e6;
    floatSink = acc;
    if (seconds <= 0) return 0;
    return iterations / seconds / 1e6;
  }

  static double _memThroughput(Duration sample) {
    const size = 4 * 1024 * 1024; // 4 MiB: maior que L2 típico de TV box
    final src = Uint8List(size);
    for (var i = 0; i < size; i += 4096) {
      src[i] = i & 0xff;
    }
    final dst = Uint8List(size);
    void work() => dst.setRange(0, size, src);

    work();
    var bytes = 0;
    final sw = Stopwatch()..start();
    do {
      work();
      bytes += size;
    } while (sw.elapsed < sample);
    final seconds = sw.elapsedMicroseconds / 1e6;
    byteSink = dst[size ~/ 2];
    if (seconds <= 0) return 0;
    return bytes / seconds / (1024 * 1024);
  }
}

@immutable
class DeviceBenchmarkResult {
  const DeviceBenchmarkResult({
    required this.intMops,
    required this.floatMops,
    required this.memMibps,
    required this.score,
    required this.elapsed,
  });

  /// Milhões de iterações inteiras por segundo.
  final double intMops;

  /// Milhões de iterações float por segundo.
  final double floatMops;

  /// MiB/s na cópia de memória.
  final double memMibps;

  /// Índice composto 0–100 usado pela detecção.
  final double score;

  final Duration elapsed;

  int get detectionScore => score.round();

  String get rawLabel =>
      'CPU ${intMops.toStringAsFixed(0)} MI/s · '
      'FP ${floatMops.toStringAsFixed(0)} MF/s · '
      'RAM ${memMibps.toStringAsFixed(0)} MiB/s';
}

/// Persistência do último benchmark (SharedPreferences).
@immutable
class BenchmarkSnapshot {
  const BenchmarkSnapshot({
    required this.score,
    required this.intMops,
    required this.floatMops,
    required this.memMibps,
    required this.at,
  });

  final double score;
  final double intMops;
  final double floatMops;
  final double memMibps;
  final DateTime at;

  int get detectionScore => score.round();
}

class DeviceBenchmarkStore {
  DeviceBenchmarkStore._();

  static const _kVersion = 'device_benchmark_version';
  static const _kScore = 'device_benchmark_score';
  static const _kInt = 'device_benchmark_int';
  static const _kFloat = 'device_benchmark_float';
  static const _kMem = 'device_benchmark_mem';
  static const _kAt = 'device_benchmark_at';

  /// `null` quando nunca rodou ou quando a fórmula mudou de versão.
  static Future<BenchmarkSnapshot?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getInt(_kVersion) ?? -1) != DeviceBenchmark.version) {
        return null;
      }
      final score = prefs.getDouble(_kScore);
      final atMs = prefs.getInt(_kAt);
      if (score == null || atMs == null) return null;
      return BenchmarkSnapshot(
        score: score,
        intMops: prefs.getDouble(_kInt) ?? 0,
        floatMops: prefs.getDouble(_kFloat) ?? 0,
        memMibps: prefs.getDouble(_kMem) ?? 0,
        at: DateTime.fromMillisecondsSinceEpoch(atMs),
      );
    } catch (e) {
      debugPrint('[DeviceBenchmark] leitura falhou: $e');
      return null;
    }
  }

  static Future<BenchmarkSnapshot> save(DeviceBenchmarkResult result) async {
    final now = DateTime.now();
    final snap = BenchmarkSnapshot(
      score: result.score,
      intMops: result.intMops,
      floatMops: result.floatMops,
      memMibps: result.memMibps,
      at: now,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kVersion, DeviceBenchmark.version);
    await prefs.setDouble(_kScore, result.score);
    await prefs.setDouble(_kInt, result.intMops);
    await prefs.setDouble(_kFloat, result.floatMops);
    await prefs.setDouble(_kMem, result.memMibps);
    await prefs.setInt(_kAt, now.millisecondsSinceEpoch);
    return snap;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kVersion);
    await prefs.remove(_kScore);
    await prefs.remove(_kInt);
    await prefs.remove(_kFloat);
    await prefs.remove(_kMem);
    await prefs.remove(_kAt);
  }
}
