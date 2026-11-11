import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/device/device_benchmark.dart';
import 'package:goanime_tv/core/device/device_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('benchmark rápido', () {
    test('runSync devolve métricas positivas e índice 0–100', () {
      final r = DeviceBenchmark.runSync(
        sample: const Duration(milliseconds: 40),
      );
      expect(r.intMops, greaterThan(0));
      expect(r.floatMops, greaterThan(0));
      expect(r.memMibps, greaterThan(0));
      expect(r.score, inInclusiveRange(0, 100));
      expect(r.detectionScore, inInclusiveRange(0, 100));
      expect(r.elapsed.inMilliseconds, greaterThanOrEqualTo(100));
      expect(r.rawLabel, contains('CPU'));
    });

    test('score satura em 0 e 100 e é monotônico', () {
      expect(DeviceBenchmark.benchmarkScore(0, 0, 0), 0);
      expect(DeviceBenchmark.benchmarkScore(1000, 1000, 100000), 100);
      final lento = DeviceBenchmark.benchmarkScore(8, 8, 500);
      final medio = DeviceBenchmark.benchmarkScore(20, 20, 1200);
      final rapido = DeviceBenchmark.benchmarkScore(50, 50, 3000);
      expect(medio, greaterThan(lento));
      expect(rapido, greaterThan(medio));
    });
  });

  group('persistência do benchmark', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('save/read faz round-trip e versiona a fórmula', () async {
      const result = DeviceBenchmarkResult(
        intMops: 21.5,
        floatMops: 18.0,
        memMibps: 1400,
        score: 63.4,
        elapsed: Duration(milliseconds: 540),
      );
      final saved = await DeviceBenchmarkStore.save(result);
      final read = await DeviceBenchmarkStore.read();
      expect(read, isNotNull);
      expect(read!.score, closeTo(63.4, 0.001));
      expect(read.intMops, closeTo(21.5, 0.001));
      expect(read.at.millisecondsSinceEpoch, saved.at.millisecondsSinceEpoch);
      expect(read.hasVideo, isFalse);
      expect(read.video, isNull);
    });

    test('save/read persiste o fps por resolução do vídeo', () async {
      const result = DeviceBenchmarkResult(
        intMops: 20,
        floatMops: 19,
        memMibps: 1200,
        score: 60,
        elapsed: Duration(milliseconds: 540),
      );
      const video = VideoBenchmark(
        fpsByHeight: {480: 29.9, 720: 21.4},
        containerFps: 30,
        hardwareDecode: true,
        elapsed: Duration(seconds: 11),
      );
      await DeviceBenchmarkStore.save(result, video: video);
      final read = await DeviceBenchmarkStore.read();
      expect(read!.hasVideo, isTrue);
      expect(read.video!.fpsFor(480), closeTo(29.9, 0.001));
      expect(read.video!.fpsFor(720), closeTo(21.4, 0.001));
      expect(read.video!.fpsFor(1080), isNull);
      expect(read.videoContainerFps, 30);
      expect(read.videoHardwareDecode, isTrue);
      expect(read.videoLabel, '480p 30 fps · 720p 21 fps');
    });

    test('novo save sem vídeo apaga a medição anterior', () async {
      const result = DeviceBenchmarkResult(
        intMops: 20,
        floatMops: 19,
        memMibps: 1200,
        score: 60,
        elapsed: Duration(milliseconds: 540),
      );
      await DeviceBenchmarkStore.save(
        result,
        video: const VideoBenchmark(fpsByHeight: {480: 30}),
      );
      expect((await DeviceBenchmarkStore.read())!.hasVideo, isTrue);
      await DeviceBenchmarkStore.save(result);
      final read = await DeviceBenchmarkStore.read();
      expect(read!.hasVideo, isFalse);
      expect(read.videoLabel, isEmpty);
    });

    test('versão antiga da fórmula é ignorada', () async {
      SharedPreferences.setMockInitialValues({
        'device_benchmark_version': DeviceBenchmark.version - 1,
        'device_benchmark_score': 99.0,
        'device_benchmark_at': DateTime.now().millisecondsSinceEpoch,
      });
      expect(await DeviceBenchmarkStore.read(), isNull);
    });

    test('clear apaga o snapshot', () async {
      await DeviceBenchmarkStore.save(
        const DeviceBenchmarkResult(
          intMops: 1,
          floatMops: 1,
          memMibps: 1,
          score: 10,
          elapsed: Duration(milliseconds: 500),
        ),
      );
      await DeviceBenchmarkStore.clear();
      expect(await DeviceBenchmarkStore.read(), isNull);
    });
  });
}
