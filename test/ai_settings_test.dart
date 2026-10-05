import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/ai_providers.dart';
import 'package:goanime_tv/core/subtitles/model_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorage.init();
    await SettingsService.instance.init();
  });

  group('Settings IA (Fase 1 — poda p/ tiers altos)', () {
    test('padrões: sensevoice + manga', () {
      expect(SettingsService.instance.sttModel, 'sensevoice');
      expect(SettingsService.instance.mtEngine, 'manga');
    });

    test('troca persiste no restart', () async {
      await SettingsService.instance.setSttModel('jav03');
      await SettingsService.instance.setMtEngine('completa');
      await SettingsService.instance.init();
      expect(SettingsService.instance.sttModel, 'jav03');
      expect(SettingsService.instance.mtEngine, 'completa');
      expect(SettingsService.instance.sttModelListenable.value, 'jav03');
      // volta ao padrão p/ não vazar entre testes
      await SettingsService.instance.setSttModel('sensevoice');
      await SettingsService.instance.setMtEngine('manga');
    });

    test('stt jav03 é válido e persiste', () async {
      await SettingsService.instance.setSttModel('jav03');
      expect(SettingsService.instance.sttModel, 'jav03');
      await SettingsService.instance.init();
      expect(SettingsService.instance.sttModel, 'jav03');
      await SettingsService.instance.setSttModel('sensevoice');
    });

    test('mt manga é válido e persiste', () async {
      await SettingsService.instance.setMtEngine('manga');
      expect(SettingsService.instance.mtEngine, 'manga');
      await SettingsService.instance.init();
      expect(SettingsService.instance.mtEngine, 'manga');
      await SettingsService.instance.setMtEngine('manga');
    });

    test('valor inválido cai no padrão novo', () async {
      await SettingsService.instance.setSttModel('xxx');
      await SettingsService.instance.setMtEngine('yyy');
      expect(SettingsService.instance.sttModel, 'sensevoice');
      expect(SettingsService.instance.mtEngine, 'manga');
    });
  });

  group('AiProviders readiness (Fase 1)', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('models_test');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    Future<void> _fakeModel(String id, List<String> files) async {
      final dir = Directory('${root.path}/$id');
      await dir.create(recursive: true);
      for (final f in files) {
        final file = File('${dir.path}/$f');
        if (f.endsWith('.gguf')) {
          // GGUF válido p/ isValidGguf: magic + tamanho esparso (~96%).
          final raf = await file.open(mode: FileMode.write);
          await raf.writeFrom(const [0x47, 0x47, 0x55, 0x46]);
          final mb = aiModelCatalog[id]?.mb ?? 900;
          await raf.truncate((mb * 1048576 * 0.96).round());
          await raf.close();
        } else {
          await file.writeAsString('x');
        }
      }
    }

    test('null sem modelo instalado', () async {
      expect(await AiProviders.makeStt(modelRootForTest: root), isNull);
      expect(await AiProviders.makeMt(modelRootForTest: root), isNull);
    });

    test('stt sensevoice pronto quando arquivos existem', () async {
      await _fakeModel(
          'sensevoice-ja', aiModelCatalog['sensevoice-ja']!.files);
      final stt = await AiProviders.makeStt(
          modelRootForTest: root, stt: 'sensevoice');
      expect(stt?.id, 'whisper-small-anime-distill');
    });

    test('stt jav03 pronto quando arquivos existem', () async {
      await _fakeModel(
          'whisper-ja-anime-v03', aiModelCatalog['whisper-ja-anime-v03']!.files);
      final stt =
          await AiProviders.makeStt(modelRootForTest: root, stt: 'jav03');
      expect(stt?.id, 'whisper-ja-anime-v03');
    });

    test('mt manga (Hy-MT2 v3 Q4) pronto quando arquivo existe', () async {
      await _fakeModel('hymt-ja-pt-manga-v3', ['model.gguf']);
      final mt =
          await AiProviders.makeMt(modelRootForTest: root, engine: 'manga');
      expect(mt?.id, 'hymt-llm');
    });

    test('mt completa (Hy-MT2 Q4) pronto quando arquivo existe', () async {
      await _fakeModel('hymt-ja-pt-q4', ['model.gguf']);
      final mt = await AiProviders.makeMt(
          modelRootForTest: root, engine: 'completa');
      expect(mt?.id, 'hymt-llm');
    });

    test('default do makeMt é manga', () async {
      await _fakeModel('hymt-ja-pt-manga-v3', ['model.gguf']);
      final mt = await AiProviders.makeMt(modelRootForTest: root);
      expect(mt?.id, 'hymt-llm');
    });
  });
}
