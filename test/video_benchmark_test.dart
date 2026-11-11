import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/device/video_benchmark.dart';

void main() {
  group('aggregateFps', () {
    test('usa a mediana das amostras (ignora pico do warmup)', () {
      final fps = aggregateFps(
        samples: const [60, 29.8, 30.1, 29.5, 29.9],
        targetFps: 30,
        elapsed: const Duration(seconds: 4),
      );
      expect(fps, closeTo(29.9, 0.001));
    });

    test('frames descartados limitam o fps entregue', () {
      // 3 s a 30 fps = 90 frames esperados; 30 descartados → 20 fps.
      final fps = aggregateFps(
        samples: const [30, 30, 30],
        targetFps: 30,
        droppedFrames: 30,
        elapsed: const Duration(seconds: 3),
      );
      expect(fps, closeTo(20, 0.001));
    });

    test('relógio do vídeo atrasado limita o fps', () {
      // 2 s de vídeo em 4 s de parede = tocando à metade da velocidade real.
      final fps = aggregateFps(
        samples: const [30, 30, 30],
        targetFps: 30,
        elapsed: const Duration(seconds: 4),
        playedSeconds: 2,
      );
      expect(fps, closeTo(15, 0.001));
    });

    test('drop não eleva um fps já baixo', () {
      final fps = aggregateFps(
        samples: const [12, 13, 12.5],
        targetFps: 30,
        droppedFrames: 3,
        elapsed: const Duration(seconds: 4),
      );
      expect(fps, closeTo(12.5, 0.001));
    });

    test('sem amostras válidas devolve null', () {
      expect(
        aggregateFps(
          samples: const [0, -1, double.nan],
          targetFps: 30,
          elapsed: const Duration(seconds: 4),
        ),
        isNull,
      );
      expect(
        aggregateFps(
          samples: const [],
          targetFps: 30,
          elapsed: const Duration(seconds: 4),
        ),
        isNull,
      );
    });

    test('clampa em 120 fps para valores absurdos', () {
      expect(
        aggregateFps(
          samples: const [999],
          targetFps: 30,
          elapsed: const Duration(seconds: 4),
        ),
        120,
      );
    });
  });

  test('assetFor aponta para os clipes empacotados', () {
    final runner = VideoBenchmarkRunner();
    expect(runner.assetFor(480), 'asset:///assets/bench/bench_480p.mp4');
    expect(runner.assetFor(1080), 'asset:///assets/bench/bench_1080p.mp4');
    expect(VideoBenchmarkRunner.heights, [480, 720, 1080]);
  });
}
