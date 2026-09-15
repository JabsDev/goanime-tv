import 'dart:io';

import '../storage/settings_service.dart';
import 'lfm_mt.dart';
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

  /// Mapeamento Settings → (modelo, task, kind). tiny traduz ja→en (rápido);
  /// base/small/sensevoice transcrevem ja (melhor; depois NLLB ou cadeia LFM).
  static const _sttKinds = {
    'tiny': ('whisper-tiny-ja', 'translate', 'whisper'),
    'base': ('whisper-base', 'transcribe', 'whisper'),
    'small': ('whisper-small', 'transcribe', 'whisper'),
    'sensevoice': ('sensevoice-ja', 'transcribe', 'sensevoice'),
  };

  static Future<SttProvider?> makeStt({
    Directory? modelRootForTest,
    String? stt,
    String? modelDirForTest,
  }) async {
    final kind = stt ?? SettingsService.instance.sttModel;
    final spec = _sttKinds[kind] ?? _sttKinds['tiny']!;
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/${spec.$1}';
    if (!await _ready(dir, spec.$1)) return null;
    return SherpaSttProvider(dir, task: spec.$2, sttKind: spec.$3);
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

  /// MT p/ job transcribe (texto JA): só NLLB serve; Marian é EN→PT.
  /// Null = sem NLLB capaz → o chamador cai p/ cadeia LFM ou tiny.
  static Future<MtProvider?> makeMtForTranscribe({
    Directory? modelRootForTest,
    AiCapability? cap,
  }) async {
    const modelId = 'nllb-600M-int8';
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = '${root.path}/$modelId';
    final capability = cap ?? AiCapability.instance;
    if (await _ready(dir, modelId) && await capability.canUseFull()) {
      return NllbMtProvider(dir);
    }
    return null;
  }

  static Future<LfmMtProvider?> makeLfm({
    Directory? modelRootForTest,
    String? modelDirForTest,
  }) async {
    const modelId = 'lfm-ja-en';
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/$modelId';
    if (!await _ready(dir, modelId)) return null;
    return LfmMtProvider(dir);
  }

  /// Cadeia JA→PT p/ transcrição: LFM JA→EN + Marian EN→PT (carga sequencial).
  /// Null = falta LFM ou Marian → chamador usa fallback tiny.
  static Future<MtProvider?> makeMtChainJaPt({
    Directory? modelRootForTest,
  }) async {
    final root = await modelsRoot(forTest: modelRootForTest);
    final lfmDir = '${root.path}/lfm-ja-en';
    final marianDir = '${root.path}/marian-en-pt-int8';
    if (!await _ready(lfmDir, 'lfm-ja-en')) return null;
    if (!await _ready(marianDir, 'marian-en-pt-int8')) return null;
    return ChainedMtProvider([
      MtStage(LfmMtProvider(lfmDir), 'ja', 'en'),
      MtStage(
          MarianMtProvider(marianDir, targetPrefix: '>>por<<'), 'en', 'pt'),
    ]);
  }

  /// Rota S usa EN→PT leve; JA pede MT conforme Settings.
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
