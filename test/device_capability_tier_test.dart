import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/device/device_profile.dart';
import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/utils/device_capability.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Liga o tier detectado ao teto de qualidade usado pelo player/detalhe.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorage.init();
    DeviceCapability.resetCache();
  });

  tearDown(() async {
    await SettingsService.instance.setUserPreference(null);
    DeviceCapability.resetCache();
  });

  void setTier(DeviceTier tier) {
    DeviceCapability.debugSetAssessment(
      DeviceAssessment(tier: tier, score: 70),
    );
  }

  test('modo completo respeita o teto do tier', () async {
    await SettingsService.instance.init();
    await SettingsService.instance.setUserPreference(false);

    setTier(DeviceTier.low);
    expect(SettingsService.instance.qualityCapHeight, 480);

    setTier(DeviceTier.mid);
    expect(SettingsService.instance.qualityCapHeight, 720);

    setTier(DeviceTier.high);
    expect(SettingsService.instance.qualityCapHeight, isNull);
  });

  test('lite automático não reduz o teto do tier (Fire Stick em 720p)', () async {
    await SettingsService.instance.init();
    // userPreference null = automático. O modo lite pode estar ativo por RAM,
    // mas o teto continua vindo da capacidade (intermediário → 720p).
    setTier(DeviceTier.mid);
    expect(SettingsService.instance.qualityCapHeight, 720);
  });

  test('lite manual força 480p mesmo em aparelho capaz', () async {
    await SettingsService.instance.init();
    await SettingsService.instance.setUserPreference(true);

    setTier(DeviceTier.high);
    expect(SettingsService.instance.qualityCapHeight, 480);

    // Tier limitado continua 480p (nunca sobe por causa do lite).
    setTier(DeviceTier.low);
    expect(SettingsService.instance.qualityCapHeight, 480);
  });

  test('intermediário em lite manual fica em 480p (não relaxa para 720p)',
      () async {
    await SettingsService.instance.init();
    await SettingsService.instance.setUserPreference(true);

    setTier(DeviceTier.mid);
    expect(SettingsService.instance.qualityCapHeight, 480);
  });
}
