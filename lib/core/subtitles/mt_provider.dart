import 'srt_parser.dart';

/// Interface de tradução offline. Carga SEQUENCIAL obrigatória: o chamador
/// faz `SttProvider.dispose()` antes de `MtProvider.load()` — nunca ambos
/// residentes (plano §carga).
abstract class MtProvider {
  String get id; // 'marian' | 'nllb' | 'lfm-ja-en' | 'a+b' (cadeia)
  Future<void> load();
  Future<String> translate(String text, {required String src, required String tgt});
  Future<void> dispose();

  /// Traduz cue a cue (chunk por frase), preservando timestamps. beam 1.
  Future<List<SrtCue>> translateCues(List<SrtCue> cues,
      {required String src, required String tgt}) async {
    final out = <SrtCue>[];
    for (final c in cues) {
      out.add(c.withText(await translate(c.text, src: src, tgt: tgt)));
    }
    return out;
  }
}

/// Uma etapa de cadeia (ex. LFM JA→EN + Marian EN→PT).
class MtStage {
  final MtProvider provider;
  final String src;
  final String tgt;
  const MtStage(this.provider, this.src, this.tgt);
}

/// Cadeia SEQUENCIAL de tradutores (cada um com seu par src→tgt fixo).
/// Load/descarrega em ordem; falha de qualquer etapa aborta tudo.
/// Exceção à regra "nunca ambos residentes": as etapas convivem (LFM+Marian
/// ≈ 430 MB de pesos, ordem de um STT base). A regra dura continua valendo
/// p/ STT vs MT (o job faz dispose do STT antes do load da cadeia).
class ChainedMtProvider extends MtProvider {
  final List<MtStage> stages;
  ChainedMtProvider(this.stages) : assert(stages.isNotEmpty);

  @override
  String get id => stages.map((s) => s.provider.id).join('+');

  @override
  Future<void> load() async {
    for (final s in stages) {
      await s.provider.load();
    }
  }

  @override
  Future<String> translate(String text,
      {required String src, required String tgt}) async {
    var cur = text;
    for (final s in stages) {
      cur = await s.provider.translate(cur, src: s.src, tgt: s.tgt);
    }
    return cur;
  }

  @override
  Future<void> dispose() async {
    for (final s in stages) {
      try {
        await s.provider.dispose();
      } catch (_) {}
    }
  }
}

/// Placeholder até o modelo Marian baixar: identidade (não traduz).
/// O job Rota S só roda quando `isReady`; isto evita tradução silenciosa
/// errada em teste/dev sem modelo.
class PassthroughMtProvider extends MtProvider {
  @override
  String get id => 'passthrough';
  @override
  Future<void> load() async {}
  @override
  Future<String> translate(String text,
          {required String src, required String tgt}) async =>
      text;
  @override
  Future<void> dispose() async {}
}

/// Interface STT (Fase 2 sherpa_onnx; Fase 3 base). Contratos primeiro.
abstract class SttProvider {
  String get id;
  Future<void> load();
  Future<List<SrtCue>> transcribe(String pcm16kPath,
      {void Function(double progress)? onProgress});
  Future<void> dispose();
}
