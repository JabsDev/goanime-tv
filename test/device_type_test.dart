import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/device/device_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => DeviceType.resetCache());
  tearDown(() => DeviceType.resetCache());

  test('parseUiModeType: 4 é TV, resto/null é celular', () {
    expect(DeviceType.parseUiModeType(4), isTrue);
    expect(DeviceType.parseUiModeType(1), isFalse);
    expect(DeviceType.parseUiModeType(null), isFalse);
  });

  test('orientationsFor: TV landscape, celular retrato travado', () {
    expect(DeviceType.orientationsFor(true), const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    expect(DeviceType.orientationsFor(false),
        const [DeviceOrientation.portraitUp]);
  });

  test('isTelevision retorna true quando o channel devolve 4', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceType.channel, (call) async => 4);
    expect(await DeviceType.isTelevision(), isTrue);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceType.channel, null);
  });

  test('isTelevision fallback false em erro', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            DeviceType.channel, (call) async => throw PlatformException(code: 'x'));
    expect(await DeviceType.isTelevision(), isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceType.channel, null);
  });
}
