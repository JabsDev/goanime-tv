import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/model_manager.dart';
import 'package:goanime_tv/core/subtitles/ai_providers.dart';
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

  test('setSttModel aceita sensevoice e persiste (item 4)', () async {
    await SettingsService.instance.init();
    await SettingsService.instance.setSttModel('sensevoice');
    expect(SettingsService.instance.sttModel, 'sensevoice');
    await SettingsService.instance.init();
    expect(SettingsService.instance.sttModel, 'sensevoice');
    await SettingsService.instance.setSttModel('tiny');
  });

  test('default em aparelho fraco é sensevoice; forte é tiny (item 4)',
      () async {
    SettingsService.lowEndOverrideForTest = true;
    await SettingsService.instance.init();
    expect(SettingsService.instance.sttModel, 'sensevoice');
    SettingsService.lowEndOverrideForTest = false;
    await SettingsService.instance.init();
    expect(SettingsService.instance.sttModel, 'tiny');
    SettingsService.lowEndOverrideForTest = null;
  });

  test('tiers publicados batem com o catálogo (q3km fora)', () async {
    expect(AiProviders.sttTierOrder, ['tiny', 'sensevoice', 'base', 'small']);
    expect(AiProviders.mtTierOrder,
        ['minima', 'leve', 'media', 'completa']);
    for (final tier in AiProviders.sttTierOrder) {
      expect(aiModelCatalog[AiProviders.sttTiers[tier]!.id], isNotNull,
          reason: 'tier $tier sem spec no catálogo');
    }
    for (final tier in AiProviders.mtTierOrder) {
      expect(aiModelCatalog[AiProviders.mtTiers[tier]], isNotNull,
          reason: 'tier $tier sem spec no catálogo');
    }
    expect(AiProviders.mtTiers.values, isNot(contains('hymt-ja-pt-q3km')));
  });
}
