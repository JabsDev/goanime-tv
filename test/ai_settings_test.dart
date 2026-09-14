import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/ai_providers.dart';
import 'package:goanime_tv/core/subtitles/nllb_mt.dart';

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
        await File('${dir.path}/$f').writeAsString('x');
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

    test('mt leve pronto quando arquivos existem', () async {
      await _fakeModel('marian-en-pt-int8', [
        'encoder_model.onnx',
        'decoder_model.onnx',
        'vocab.json',
        'config.json',
        'generation_config.json'
      ]);
      final mt = await AiProviders.makeMt(modelRootForTest: root);
      expect(mt?.id, 'marian');
    });

    test('nllb exige arquivos + capability', () async {
      await _fakeModel('nllb-600M-int8', [
        'encoder_model.onnx',
        'decoder_model.onnx',
        'decoder_with_past_model.onnx',
        'tokenizer.model'
      ]);
      const strong = AiCapability(
          isLowEndForTest: _no, freeBytesForTest: _plenty);
      const weak =
          AiCapability(isLowEndForTest: _yes, freeBytesForTest: _plenty);
      final ok = await AiProviders.makeMt(
          modelRootForTest: root, engine: 'completa', cap: strong);
      expect(ok?.id, 'nllb');
      expect(
          await AiProviders.makeMt(
              modelRootForTest: root, engine: 'completa', cap: weak),
          isNull);
    });
  });
}

Future<bool> _no() async => false;
Future<bool> _yes() async => true;
Future<int> _plenty() async => 8 * 1024 * 1024 * 1024;
