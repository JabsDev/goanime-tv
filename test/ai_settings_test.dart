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

  group('Settings IA (Fase 4)', () {
    test('padrões: tiny + leve', () {
      expect(SettingsService.instance.sttModel, 'tiny');
      expect(SettingsService.instance.mtEngine, 'leve');
    });

    test('troca persiste no restart', () async {
      await SettingsService.instance.setSttModel('base');
      await SettingsService.instance.setMtEngine('completa');
      await SettingsService.instance.init();
      expect(SettingsService.instance.sttModel, 'base');
      expect(SettingsService.instance.mtEngine, 'completa');
      expect(SettingsService.instance.sttModelListenable.value, 'base');
      // volta ao padrão p/ não vazar entre testes
      await SettingsService.instance.setSttModel('tiny');
      await SettingsService.instance.setMtEngine('leve');
    });

    test('stt small é válido e persiste', () async {
      await SettingsService.instance.setSttModel('small');
      expect(SettingsService.instance.sttModel, 'small');
      await SettingsService.instance.init();
      expect(SettingsService.instance.sttModel, 'small');
      await SettingsService.instance.setSttModel('tiny');
    });

    test('mt media é válido e persiste', () async {
      await SettingsService.instance.setMtEngine('media');
      expect(SettingsService.instance.mtEngine, 'media');
      await SettingsService.instance.init();
      expect(SettingsService.instance.mtEngine, 'media');
      await SettingsService.instance.setMtEngine('leve');
    });

    test('valor inválido cai no padrão', () async {
      await SettingsService.instance.setSttModel('xxx');
      await SettingsService.instance.setMtEngine('yyy');
      expect(SettingsService.instance.sttModel, 'tiny');
      expect(SettingsService.instance.mtEngine, 'leve');
    });
  });

  group('AiProviders readiness', () {
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

    test('stt small pronto quando arquivos existem', () async {
      await _fakeModel('whisper-small',
          ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']);
      final stt =
          await AiProviders.makeStt(modelRootForTest: root, stt: 'small');
      expect(stt?.id, 'whisper-small');
    });

    test('stt tiny pronto quando arquivos existem', () async {
      await _fakeModel('whisper-tiny-ja',
          ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']);
      final stt =
          await AiProviders.makeStt(modelRootForTest: root, stt: 'tiny');
      expect(stt?.id, 'whisper-tiny-ja');
    });

    test('mt leve (LFM 1.2B) pronto quando arquivo existe', () async {
      await _fakeModel('lfm12b-ja-pt-iq3m', ['model.gguf']);
      final mt = await AiProviders.makeMt(modelRootForTest: root);
      expect(mt?.id, 'hymt-llm');
    });

    test('mt media (Hy-MT2 IQ3) pronto quando arquivo existe', () async {
      await _fakeModel('hymt-ja-pt-iq3m', ['model.gguf']);
      final mt = await AiProviders.makeMt(
          modelRootForTest: root, engine: 'media');
      expect(mt?.id, 'hymt-llm');
    });

    test('mt completa (Hy-MT2 Q4) pronto quando arquivo existe', () async {
      await _fakeModel('hymt-ja-pt-q4', ['model.gguf']);
      final mt = await AiProviders.makeMt(
          modelRootForTest: root, engine: 'completa');
      expect(mt?.id, 'hymt-llm');
    });
  });
}
