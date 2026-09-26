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
      final file = File('$modelDir/$f');
      if (f.endsWith('.gguf')) {
        if (!await ModelManager.isValidGguf(file, spec.mb)) return false;
      } else if (!await file.exists()) {
        return false;
      }
    }
    return true;
  }

  /// Mapeamento Settings → (modelo, task, kind). tiny traduz ja→en (rápido);
  /// base/small/sensevoice transcrevem ja (melhor; depois Hy-MT2 direto).
  /// Mapa publicado (fonte única de verdade — telas consomem, nunca copiam).
  static const sttTiers = <String, ({String id, String task, String kind})>{
    'tiny': (id: 'whisper-tiny-ja', task: 'translate', kind: 'whisper'),
    'sensevoice': (id: 'sensevoice-ja', task: 'transcribe', kind: 'sensevoice'),
    'base': (id: 'whisper-base', task: 'transcribe', kind: 'whisper'),
    'small': (id: 'whisper-small', task: 'transcribe', kind: 'whisper'),
  };
  static const sttTierOrder = ['tiny', 'sensevoice', 'base', 'small'];

  /// Labels curtos p/ as linhas de modelo (o `label` do catálogo é longo).
  static const sttTierLabels = {
    'tiny': 'Whisper tiny',
    'sensevoice': 'SenseVoice',
    'base': 'Whisper base',
    'small': 'Whisper small',
  };

  /// MT via llama.cpp, em escada de tamanho/qualidade (gate próprio, 6 frases):
  /// 'minima' = Qwen 0.6B Q4 (~378 MB, 4/6), 'leve' = LFM 1.2B IQ3 (~541 MB,
  /// 5/6), 'media' = Hy-MT2 IQ3 (~859 MB, 6/6), 'completa' = Hy-MT2 Q4
  /// (~1,13 GB, 6/6). Q3 (~907 MB) segue no catálogo p/ quem já baixou,
  /// mas sem engine (superado pelo IQ3).
  /// Todos cobrem JA→PT direto e EN→PT (Rota S).
  static const mtTiers = <String, String>{
    'minima': 'qwen06-ja-pt-q4',
    'leve': 'lfm12b-ja-pt-iq3m',
    'media': 'hymt-ja-pt-iq3m',
    'completa': 'hymt-ja-pt-q4',
  };
  static const mtTierOrder = ['minima', 'leve', 'media', 'completa'];
  static const mtTierLabels = {
    'minima': 'Qwen 0.6B Q4_K_M',
    'leve': 'LFM 1.2B IQ3_M',
    'media': 'Hy-MT2 IQ3_M',
    'completa': 'Hy-MT2 Q4_K_M',
  };

  static Future<SttProvider?> makeStt({
    Directory? modelRootForTest,
    String? stt,
    String? modelDirForTest,
  }) async {
    final kind = stt ?? SettingsService.instance.sttModel;
    final spec = sttTiers[kind] ?? sttTiers['tiny']!;
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/${spec.id}';
    if (!await _ready(dir, spec.id)) return null;
    return SherpaSttProvider(dir, task: spec.task, sttKind: spec.kind);
  }

  /// MT via llama.cpp, em escada de tamanho/qualidade (gate próprio, 6 frases):
  /// 'minima' = Qwen 0.6B Q4 (~378 MB, 4/6), 'leve' = LFM 1.2B IQ3 (~541 MB,
  /// 5/6), 'media' = Hy-MT2 IQ3 (~859 MB, 6/6), 'completa' = Hy-MT2 Q4
  /// (~1,13 GB, 6/6). Q3 (~907 MB) segue no catálogo p/ quem já baixou,
  /// mas sem engine (superado pelo IQ3).
  /// Todos cobrem JA→PT direto e EN→PT (Rota S).
  static Future<MtProvider?> makeMt({
    Directory? modelRootForTest,
    String? engine,
    String? modelDirForTest,
  }) async {
    final kind = engine ?? SettingsService.instance.mtEngine;
    final modelId = mtTiers[kind] ?? mtTiers['leve']!;
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/$modelId';
    if (!await _ready(dir, modelId)) return null;
    return LlmMtProvider('$dir/model.gguf',
        expectedMb: aiModelCatalog[modelId]!.mb);
  }

  /// 1 único probe p/ todos os tiers (tela e card não re-probam por linha
  /// — antes cada `_ModelRow`/`_ModelOptionRow` rodava um FutureBuilder de
  /// IO por build). Falha de IO vira "faltando" (nunca quebra a tela).
  static Future<Map<String, bool>> readyMap(
    Iterable<String> ids, {
    Directory? modelRootForTest,
  }) async {
    final root = await modelsRoot(forTest: modelRootForTest);
    final out = <String, bool>{};
    for (final id in ids) {
      final dir = '${root.path}/$id';
      try {
        out[id] = await _ready(dir, id);
      } catch (_) {
        out[id] = false;
      }
    }
    return out;
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
