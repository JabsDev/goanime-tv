import 'dart:io';

import '../storage/settings_service.dart';
import 'marian_mt.dart';
import 'model_manager.dart';
import 'mt_provider.dart';
import 'nllb_mt.dart';
import 'sherpa_stt.dart';

/// Fábrica dos providers reais conforme Settings (STT tiny/base, MT
/// leve/completa). Retorna null quando o modelo não está instalado — o
/// chamador (picker) informa o usuário em vez de falhar silencioso.
/// `modelRootForTest`/`stt`/`engine`/`cap` injetáveis p/ teste sem nativo.
class AiProviders {
  const AiProviders._();

  static Future<Directory> modelsRoot({Directory? forTest}) async =>
      forTest ?? await const ModelManager().modelsDir();

  static Future<bool> _ready(String modelDir, String modelId) async {
    final spec = aiModelCatalog[modelId];
    if (spec == null) return false;
    for (final f in spec.files) {
      if (!await File('$modelDir/$f').exists()) return false;
    }
    return true;
  }

  static Future<SttProvider?> makeStt({
    Directory? modelRootForTest,
    String? stt,
    String? modelDirForTest,
  }) async {
    final kind = stt ?? SettingsService.instance.sttModel;
    final modelId = kind == 'base' ? 'whisper-base' : 'whisper-tiny-ja';
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/$modelId';
    if (!await _ready(dir, modelId)) return null;
    return SherpaSttProvider(dir,
        task: kind == 'base' ? 'transcribe' : 'translate');
  }

  static Future<MtProvider?> makeMt({
    Directory? modelRootForTest,
    String? engine,
    String? modelDirForTest,
    AiCapability? cap,
  }) async {
    final kind = engine ?? SettingsService.instance.mtEngine;
    if (kind == 'completa') {
      const modelId = 'nllb-600M-int8';
      final root = await modelsRoot(forTest: modelRootForTest);
      final dir = modelDirForTest ?? '${root.path}/$modelId';
      final capability = cap ?? AiCapability.instance;
      if (await _ready(dir, modelId) && await capability.canUseFull()) {
        return NllbMtProvider(dir);
      }
      return null;
    }
    const modelId = 'marian-en-pt-int8';
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/$modelId';
    if (!await _ready(dir, modelId)) return null;
    // opus-mt-en-mul exige alvo >>por<< na entrada.
    return MarianMtProvider(dir, targetPrefix: '>>por<<');
  }

  /// Rota S usa EN→PT leve; L1-transcribe usa STT + MT conforme Settings.
  static Future<MtProvider?> makeMtForSrc(String srcLang,
      {Directory? modelRootForTest,
      String? engine,
      AiCapability? cap}) async {
    if (srcLang == 'ja') return makeMt(
        modelRootForTest: modelRootForTest, engine: engine, cap: cap);
    return makeMt(
        modelRootForTest: modelRootForTest, engine: 'leve', cap: cap);
  }
}
