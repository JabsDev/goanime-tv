import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/utils/nsfw_filter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorage.init();
  });

  test('filtro NSFW vem ativado por padrão (strict)', () async {
    await SettingsService.instance.init();
    expect(SettingsService.instance.nsfwFilterLevel, NsfwFilterSetting.strict);
  });

  test('alterar nível persiste e o next init lê do disco', () async {
    await SettingsService.instance.init();
    await SettingsService.instance.setNsfwFilterLevel(NsfwFilterSetting.soft);
    expect(SettingsService.instance.nsfwFilterLevel, NsfwFilterSetting.soft);

    // Simula restart: novo init com o mesmo mock de prefs.
    await SettingsService.instance.init();
    expect(SettingsService.instance.nsfwFilterLevel, NsfwFilterSetting.soft);
  });

  test('desativar filtro libera todo conteúdo', () async {
    await SettingsService.instance.init();
    await SettingsService.instance.setNsfwFilterLevel(NsfwFilterSetting.off);
    expect(SettingsService.instance.nsfwFilterLevel, NsfwFilterSetting.off);
    expect(
        SettingsService.instance.nsfwFilterListenable.value,
        NsfwFilterSetting.off);
  });
}
