import 'dart:io';

import '../storage/settings_service.dart';
import 'llm_mt.dart';
import 'model_manager.dart';
import 'mt_provider.dart';
import 'sherpa_stt.dart';

/// Fábrica dos providers reais conforme Settings (STT tiny/base/sensevoice,
/// MT leve/completa = Hy-MT2 Q3/Q4 via llama.cpp). Retorna null quando o
/// modelo não está instalado — o chamador informa o usuário em vez de
/// falhar silencioso. `modelRootForTest`/`stt`/`engine` injetáveis p/ teste.
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
  /// base/small/sensevoice transcrevem ja (melhor; depois Hy-MT2 direto).
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

  /// MT Hy-MT2 via llama.cpp: 'leve' = Q3_K_M (~907 MB), 'completa' = Q4_K_M
  /// (~1,13 GB). Mesmo provider cobre JA→PT direto e EN→PT (Rota S).
  static const _mtIds = {
    'leve': 'hymt-ja-pt-q3km',
    'completa': 'hymt-ja-pt-q4',
  };

  static Future<MtProvider?> makeMt({
    Directory? modelRootForTest,
    String? engine,
    String? modelDirForTest,
  }) async {
    final kind = engine ?? SettingsService.instance.mtEngine;
    final modelId = _mtIds[kind] ?? _mtIds['leve']!;
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/$modelId';
    if (!await _ready(dir, modelId)) return null;
    return LlmMtProvider('$dir/model.gguf');
  }

  /// Rota S (EN/ES→PT) e transcribe (JA→PT) usam o mesmo provider Hy-MT2.
  static Future<MtProvider?> makeMtForSrc(String srcLang,
      {Directory? modelRootForTest, String? engine}) async {
    if (srcLang != 'en' && srcLang != 'ja' && srcLang != 'es') return null;
    // Rota S hoje só entra com EN/ES; ES cai p/ EN (limitação honesta do
    // prompt atual — Hy-MT2 cobre ES, fiação futura).
    return makeMt(
        modelRootForTest: modelRootForTest,
        engine: srcLang == 'ja' ? engine : 'leve');
  }
}
