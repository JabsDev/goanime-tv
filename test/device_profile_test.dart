import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/device/device_profile.dart';

/// Regressão do bug real: Fire Stick Lite (A53 @1,7 GHz) e projetor H713
/// (A53 @1,3 GHz) têm os dois 1 GB de RAM, mas só o primeiro toca HD com
/// folga. O teto de qualidade precisa seguir a capacidade, não só a RAM.
void main() {
  Map<String, CodecSupport> codecs({
    bool h264Hw = true,
    int h264Height = 1080,
    bool hevcHw = true,
    int hevcHeight = 1080,
    bool vp9Hw = true,
    bool av1Hw = false,
  }) => {
    kMimeH264: CodecSupport(
      hardware: h264Hw,
      maxWidth: (h264Height * 16 / 9).round(),
      maxHeight: h264Height,
    ),
    kMimeHevc: CodecSupport(
      hardware: hevcHw,
      maxWidth: (hevcHeight * 16 / 9).round(),
      maxHeight: hevcHeight,
    ),
    kMimeVp9: CodecSupport(hardware: vp9Hw, maxWidth: 1920, maxHeight: 1080),
    kMimeAv1: CodecSupport(
      hardware: av1Hw,
      maxWidth: av1Hw ? 3840 : 0,
      maxHeight: av1Hw ? 2160 : 0,
    ),
  };

  DeviceProfile profile({
    int? freq = 1300,
    int cores = 4,
    bool is64Bit = false,
    bool neon = true,
    int totalRamMb = 1024,
    int availableRamMb = 400,
    bool lowRamDevice = false,
    Map<String, CodecSupport>? codecMap,
  }) => DeviceProfile(
    model: 'test',
    manufacturer: 'test',
    hardware: 'test',
    androidRelease: '11',
    sdkInt: 30,
    abis: const ['armeabi-v7a'],
    is64Bit: is64Bit,
    neon: neon,
    cores: cores,
    cpuMaxFreqMhz: freq,
    totalRamMb: totalRamMb,
    availableRamMb: availableRamMb,
    lowRamDevice: lowRamDevice,
    memoryClassMb: 192,
    codecs: codecMap ?? codecs(),
  );

  group('tier por capacidade (não só RAM)', () {
    test('projetor H713 1,3 GHz → limitado, teto 480p', () {
      final a = assessDevice(profile(freq: 1300));
      expect(a.tier, DeviceTier.low);
      expect(a.maxQualityHeight, 480);
    });

    test('Fire Stick 1,7 GHz com a mesma RAM → intermediário, teto 720p', () {
      final a = assessDevice(profile(freq: 1700));
      expect(a.tier, DeviceTier.mid);
      expect(a.maxQualityHeight, 720);
    });

    test('aparelho forte (8 núcleos/64 bits/3 GB/AV1) → capaz sem teto', () {
      final a = assessDevice(
        profile(
          freq: 1900,
          cores: 8,
          is64Bit: true,
          totalRamMb: 3072,
          availableRamMb: 1600,
          codecMap: codecs(av1Hw: true),
        ),
      );
      expect(a.tier, DeviceTier.high);
      expect(a.maxQualityHeight, isNull);
    });
  });

  group('travas duras', () {
    test('sem H.264 de hardware em 720p → limitado mesmo com CPU forte', () {
      final a = assessDevice(
        profile(
          freq: 2200,
          cores: 8,
          is64Bit: true,
          totalRamMb: 8192,
          availableRamMb: 4000,
          codecMap: codecs(h264Hw: false),
        ),
      );
      expect(a.tier, DeviceTier.low);
      expect(a.score, anyOf(isNotNull));
      expect(a.reasons.any((r) => r.contains('H.264')), isTrue);
    });

    test('1 GB de RAM nunca vira "capaz" (buffer estoura antes da CPU)', () {
      final a = assessDevice(
        profile(
          freq: 1900,
          cores: 8,
          is64Bit: true,
          totalRamMb: 1024,
          availableRamMb: 600,
          codecMap: codecs(av1Hw: true),
        ),
      );
      expect(a.tier, DeviceTier.mid);
      expect(a.maxQualityHeight, 720);
    });

    test('low-RAM do Android limita a intermediário até 2 GB', () {
      final a = assessDevice(
        profile(
          freq: 2100,
          cores: 8,
          is64Bit: true,
          totalRamMb: 2048,
          availableRamMb: 1200,
          lowRamDevice: true,
          codecMap: codecs(av1Hw: true),
        ),
      );
      expect(a.tier, DeviceTier.mid);
    });
  });

  test('benchmark substitui clock ausente e melhora o score', () {
    final p = profile(
      freq: null,
      cores: 8,
      is64Bit: true,
      totalRamMb: 3072,
      availableRamMb: 1600,
      codecMap: codecs(av1Hw: true),
    );
    final semBench = assessDevice(p);
    final comBench = assessDevice(p, benchmarkScore: 90);
    expect(comBench.score, greaterThan(semBench.score));
    expect(comBench.benchmarkUsed, isTrue);
    expect(comBench.reasons.any((r) => r.contains('benchmark')), isTrue);
  });

  test('benchmark não inventa capacidade em aparelho limitado', () {
    // Mesmo com score máximo, 1 GB + 1,3 GHz continua limitado: o benchmark
    // entra no bucket dele (5–15), não no clock já conhecido.
    final p = profile(freq: 1300, is64Bit: true);
    final a = assessDevice(p, benchmarkScore: 100);
    expect(a.tier, DeviceTier.low);
    expect(a.reasons.any((r) => r.contains('1,4 GHz')), isTrue);
  });

  test('fromMap tolera campos ausentes, tipos errados e codecs vazios', () {
    final p = DeviceProfile.fromMap({
      'model': 'x',
      'cores': '4',
      'cpuMaxFreqMhz': 0,
      'is64Bit': 1,
      'abis': ['arm64-v8a', 42],
      'codecs': {
        kMimeH264: {'hardware': true, 'maxHeight': 1080},
        'lixo': 'não é mapa',
      },
    });
    expect(p.cores, 4);
    expect(p.cpuMaxFreqMhz, isNull);
    expect(p.is64Bit, isTrue);
    expect(p.abis, ['arm64-v8a']);
    expect(p.codecs[kMimeH264]!.supportsHeight(1080), isTrue);
    expect(p.codecs[kMimeH264]!.maxWidth, 0);
    expect(p.codecs.containsKey('lixo'), isFalse);
  });

  test('shortLabel resume hardware/software e resolução', () {
    expect(
      const CodecSupport(hardware: true, maxHeight: 1080).shortLabel,
      'HW 1080p',
    );
    expect(
      const CodecSupport(hardware: false, maxHeight: 720).shortLabel,
      'SW 720p',
    );
    expect(const CodecSupport(hardware: false).shortLabel, '—');
  });

  group('benchmark de vídeo (fps real) define o nível', () {
    VideoBenchmark video(
      Map<int, double> fps, {
      double target = 30,
      bool hw = true,
    }) => VideoBenchmark(
      fpsByHeight: fps,
      containerFps: target,
      hardwareDecode: hw,
      elapsed: const Duration(seconds: 14),
    );

    test('clipes de 30 fps: 25,5 fps é o piso de tempo real', () {
      expect(videoRequiredFps(30), closeTo(25.5, 0.001));
      expect(videoSustainsFps(26, 30), isTrue);
      expect(videoSustainsFps(24, 30), isFalse);
      // Piso de 20 fps vale para fontes lentas (24 fps).
      expect(videoRequiredFps(24), closeTo(20.4, 0.001));
    });

    test('sustenta 1080p → capaz, sem teto', () {
      final a = assessDevice(
        profile(freq: 1900, cores: 8, is64Bit: true, totalRamMb: 3072),
        video: video({480: 30, 720: 29.5, 1080: 28.8}),
      );
      expect(a.tier, DeviceTier.high);
      expect(a.maxQualityHeight, isNull);
      expect(a.videoBenchmarkUsed, isTrue);
      expect(a.reasons.any((r) => r.contains('1080p')), isTrue);
    });

    test('sustenta 720p e falha 1080p → intermediário', () {
      final a = assessDevice(
        profile(freq: 1700),
        video: video({480: 29.9, 720: 28.2, 1080: 12.0}),
      );
      expect(a.tier, DeviceTier.mid);
      expect(a.maxQualityHeight, 720);
    });

    test('só 480p → limitado', () {
      final a = assessDevice(profile(), video: video({480: 29, 720: 9}));
      expect(a.tier, DeviceTier.low);
      expect(a.maxQualityHeight, 480);
      expect(a.score, lessThan(kLowTierMaxScore));
    });

    test('nem 480p → limitado com score baixo', () {
      final a = assessDevice(profile(), video: video({480: 8}));
      expect(a.tier, DeviceTier.low);
      expect(a.score, lessThan(40));
    });

    test('vídeo manda sobre a trava estática do projetor', () {
      // Antes, 1 GB + 1,3 GHz virava limitado mesmo tocando 720p. A medição
      // real substitui a heurística.
      final a = assessDevice(
        profile(freq: 1300),
        video: video({480: 29.5, 720: 27.0}),
      );
      expect(a.tier, DeviceTier.mid);
      expect(a.reasons.any((r) => r.contains('1,4 GHz')), isFalse);
    });

    test('RAM de 1 GB ainda impede "capaz" mesmo tocando 1080p', () {
      final a = assessDevice(
        profile(freq: 1900, totalRamMb: 1024),
        video: video({480: 30, 720: 30, 1080: 29}),
      );
      expect(a.tier, DeviceTier.mid);
      expect(a.reasons.any((r) => r.contains('1,5 GB')), isTrue);
    });

    test('benchmark de vídeo vazio cai no perfil estático', () {
      final a = assessDevice(
        profile(freq: 1300),
        video: const VideoBenchmark(fpsByHeight: {}),
      );
      expect(a.tier, DeviceTier.low);
      expect(a.videoBenchmarkUsed, isFalse);
    });

    test('sustainedHeight/videoTier resumem o mapa de fps', () {
      final v = video({480: 30, 720: 26.0, 1080: 20});
      expect(v.sustainedHeight, 720);
      expect(videoTier(v), DeviceTier.mid);
      expect(videoScore(v), inInclusiveRange(62, 79));
    });
  });
}
