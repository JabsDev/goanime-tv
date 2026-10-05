import 'dart:io';

import '../storage/settings_service.dart';
import 'audit_engine.dart';
import 'auditor.dart';
import 'jav03_stt.dart';
import 'llm_mt.dart';
import 'model_manager.dart';
import 'mt_provider.dart';
import 'seq2seq_audit.dart';
import 'sherpa_stt.dart';

/// Fábrica dos providers reais conforme Settings (Fase 1: STT
/// sensevoice/jav03, MT manga/completa via llama.cpp). Retorna null quando o
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

  /// Mapeamento Settings → (modelo, task, kind).
  /// Poda Fase 1: só os tiers ALTOS. `sensevoice` = Whisper-small destilado
  /// em anime (motor ORT, ~420 MB, roda em aparelho fraco); `jav03` =
  /// whisper-ja-anime-v0.3 (~900 MB, melhor CER medido). Os tiers baixos
  /// (tiny/base/small/anime-whisper) saíram: pequenos demais alucinavam.
  /// Mapa publicado (fonte única de verdade — telas consomem, nunca copiam).
  static const sttTiers = <String, ({String id, String task, String kind})>{
    'sensevoice': (id: 'sensevoice-ja', task: 'transcribe', kind: 'jav03'),
    'jav03': (id: 'whisper-ja-anime-v03', task: 'transcribe', kind: 'jav03'),
  };
  static const sttTierOrder = ['sensevoice', 'jav03'];

  /// Labels curtos p/ as linhas de modelo (o `label` do catálogo é longo).
  static const sttTierLabels = {
    'sensevoice': 'Whisper anime leve',
    'jav03': 'Whisper anime v0.3',
  };

  /// MT via llama.cpp. Poda Fase 1: só os tiers ALTOS (JA→PT direto, e EN→PT
  /// na Rota S). 'manga' = Hy-MT2 1.8B fine-tune de mangá Q4 (~1,13 GB), o
  /// melhor medido (0 japonês / 0 cópia, traduz fala de pausa sem alucinar);
  /// 'completa' = Hy-MT2 Q4 base (~1,13 GB), alternativa genérica. Os tiers
  /// baixos (minima/anime/leve/lmt) saíram: devolviam japonês/cópias no holdout.
  static const mtTiers = <String, String>{
    'manga': 'hymt-ja-pt-manga-v3',
    'completa': 'hymt-ja-pt-q4',
  };
  static const mtTierOrder = ['manga', 'completa'];
  static const mtTierLabels = {
    'manga': 'Hy-MT2 v3 mangá Q4',
    'completa': 'Hy-MT2 Q4_K_M',
  };

  static Future<SttProvider?> makeStt({
    Directory? modelRootForTest,
    String? stt,
    String? modelDirForTest,
  }) async {
    final kind = stt ?? SettingsService.instance.sttModel;
    final spec = sttTiers[kind] ?? sttTiers['sensevoice']!;
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/${spec.id}';
    if (!await _ready(dir, spec.id)) return null;
    if (spec.kind == 'jav03') {
      // dois modelos usam o motor ORT: o v0.3 e o student destilado. Cada um
      // tem seu prefixo de prompt e seus nomes de arquivo.
      if (spec.id == 'sensevoice-ja') {
        return Jav03SttProvider(dir,
            task: spec.task,
            promptIds: const [50258, 50266, 50359, 50363, 50257],
            files: const [
              'mel.onnx',
              'encoder_model.int8.onnx',
              'decoder_model.int8.onnx',
            ],
            providerId: 'whisper-small-anime-distill');
      }
      return Jav03SttProvider(dir, task: spec.task);
    }
    return SherpaSttProvider(dir, task: spec.task, sttKind: spec.kind);
  }

  /// Auditorias de legenda (modo teste): sobe o LLM leve DIFERENTE do
  /// tradutor. O id vem de Settings.auditKind; null = modelo não instalado
  /// (o chamador explica) ou 'off'.
  static Future<AuditEngine?> makeAudit({
    Directory? modelRootForTest,
    String? kind,
    String? modelDirForTest,
  }) async {
    final k = kind ?? SettingsService.instance.auditKind;
    if (k == 'off') return null;
    final root = await modelsRoot(forTest: modelRootForTest);
    final dir = modelDirForTest ?? '${root.path}/$k';
    if (!await _ready(dir, k)) return null;
    // Auditor seq2seq (ByT5 ONNX, só JA) vs LLM GGUF (llama.cpp).
    if (k == seq2seqAuditId) return Seq2SeqAuditProvider(dir);
    return AuditProvider('$dir/auditor.gguf');
  }

  /// Auditor seq2seq próprio (ja-seq2seq): tier == id de catálogo.
  static const seq2seqAuditId = 'ja-seq2seq';

  /// Auditoria de legenda (opcional). Ordem de exibição na tela; 'off' primeiro.
  static const auditTierOrder = <String>[
    'off', 'ja-seq2seq', 'heretic-1b-it', 'qwen3-06b',
    'lfm25-dist', 'lfm12b-audit',
  ];

  static const auditTierLabels = <String, String>{
    'off': 'Desligada',
    'ja-seq2seq': 'Auditor JA seq2seq (rápido · ~551 MB)',
    'heretic-1b-it': 'Auditor gemma-3 1B (Heretic)',
    'qwen3-06b': 'Auditor Qwen3 0.6B',
    'lfm25-dist': 'Auditor LFM dist 350M',
    'lfm12b-audit': 'Auditor LFM 1.2B',
  };

  /// MT via llama.cpp. O id do modelo vem do tier ativo (ver [mtTiers]).
  static Future<MtProvider?> makeMt({
    Directory? modelRootForTest,
    String? engine,
    String? modelDirForTest,
  }) async {
    final kind = engine ?? SettingsService.instance.mtEngine;
    final modelId = mtTiers[kind] ?? mtTiers['manga']!;
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
        engine: srcLang == 'ja' ? engine : 'manga');
  }
}
