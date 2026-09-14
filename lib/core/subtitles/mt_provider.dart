import 'srt_parser.dart';

/// Interface de tradução offline. Carga SEQUENCIAL obrigatória: o chamador
/// faz `SttProvider.dispose()` antes de `MtProvider.load()` — nunca ambos
/// residentes (plano §carga).
abstract class MtProvider {
  String get id; // 'marian' | 'nllb'
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
