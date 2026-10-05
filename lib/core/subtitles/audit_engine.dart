import 'srt_parser.dart';

/// Interface comum dos auditores de legenda: LLM GGUF (llama.cpp) ou
/// seq2seq ONNX (ByT5). O job de legenda só conhece esta interface — troca de
/// engine sem mexer no pipeline.
abstract class AuditEngine {
  Future<void> load();
  Future<List<SrtCue>> auditJa(List<SrtCue> cues,
      {bool Function()? isCancelled});
  Future<List<SrtCue>> auditPt(List<SrtCue> cues,
      {bool Function()? isCancelled});
  Future<void> dispose();
}
