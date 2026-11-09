import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/device/device_benchmark.dart';
import 'package:goanime_tv/core/device/device_hardware.dart';
import 'package:goanime_tv/core/device/device_profile.dart';
import 'package:goanime_tv/core/utils/device_capability.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<Object?, Object?> codecs({
    bool av1 = false,
  }) =>
      <Object?, Object?>{
        kMimeH264: <Object?, Object?>{
          'hardware': true,
          'maxWidth': 1920,
          'maxHeight': 1080,
        },
        kMimeHevc: <Object?, Object?>{
          'hardware': true,
          'maxWidth': 1920,
          'maxHeight': 1080,
        },
        kMimeVp9: <Object?, Object?>{
          'hardware': true,
          'maxWidth': 1920,
          'maxHeight': 1080,
        },
        if (av1)
          kMimeAv1: <Object?, Object?>{
            'hardware': true,
            'maxWidth': 3840,
            'maxHeight': 2160,
          },
      };

  Map<Object?, Object?> device({
    required String model,
    required int freq,
    required bool is64Bit,
    bool av1 = false,
  }) =>
      <Object?, Object?>{
        'model': model,
        'manufacturer': 'test',
        'hardware': 'test',
        'androidRelease': '11',
        'sdkInt': 30,
        'abis': is64Bit ? ['arm64-v8a'] : ['armeabi-v7a'],
        'is64Bit': is64Bit,
        'neon': true,
        'cores': 4,
        'cpuMaxFreqMhz': freq,
        'totalRamMb': 1024,
        'availableRamMb': 400,
        'lowRamDevice': false,
        'memoryClassMb': 192,
        'codecs': codecs(av1: av1),
      };

  void mock(Map<Object?, Object?> profile) {
    messenger.setMockMethodCallHandler(
      DeviceHardware.channel,
      (call) async => call.method == 'profile' ? profile : null,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceCapability.resetCache();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(DeviceHardware.channel, null);
    DeviceCapability.resetCache();
  });

  test('perfil do canal: projetor 1,3 GHz → limitado; Fire Stick → 720p',
      () async {
    mock(device(model: 'HY320', freq: 1300, is64Bit: false));
    final projector = await DeviceCapability.load();
    expect(DeviceCapability.profile!.model, 'HY320');
    expect(projector.tier, DeviceTier.low);
    expect(projector.maxQualityHeight, 480);
    expect(await DeviceCapability.isLowEnd(), isTrue);

    // Mesmo aparelho, CPU mais rápida: sobe para intermediário.
    mock(device(model: 'AFTSSS', freq: 1700, is64Bit: false));
    final fireStick = await DeviceCapability.load(refresh: true);
    expect(fireStick.tier, DeviceTier.mid);
    expect(fireStick.maxQualityHeight, 720);
  });

  test('benchmark persistido entra na reavaliação do perfil', () async {
    mock(device(model: 'HY320', freq: 1300, is64Bit: false));
    await DeviceCapability.load();

    final before = DeviceCapability.assessment.score;
    final after = await DeviceCapability.applyBenchmark(
      const DeviceBenchmarkResult(
        intMops: 30,
        floatMops: 25,
        memMibps: 1800,
        score: 85,
        elapsed: Duration(milliseconds: 600),
      ),
    );
    expect(after.benchmarkUsed, isTrue);
    expect(after.score, greaterThan(before));
    // A trava de 1 GB + 1,3 GHz mantém o projetor em 480p mesmo assim.
    expect(after.tier, DeviceTier.low);
    expect(DeviceCapability.benchmark!.detectionScore, 85);
  });
}
