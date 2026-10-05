import 'package:flutter/services.dart';

import 'audit_engine.dart';
import 'srt_parser.dart';

/// Auditor JA seq2seq (ByT5 fine-tunado, int8) rodando pelo ONNX Runtime
/// nativo (channel `goanime/seq2seq_audit`). O nativo faz o byte-level:
/// entrada = bytes+3 com EOS; saída = bytes. Sem tokenizer externo.
class Seq2SeqAuditProvider implements AuditEngine {
  static const _ch = MethodChannel('goanime/seq2seq_audit');

  final String modelDir;
  final String encoder;
  final String decoder;
  final int threads;

  Seq2SeqAuditProvider(
    this.modelDir, {
    this.encoder = 'encoder.onnx',
    this.decoder = 'decoder.onnx',
    this.threads = 4,
  });

  /// As sessoes ONNX carregam no 1o fix (lazy); aqui so satisfaz a interface.
  @override
  Future<void> load() async {}

  Future<String> fix(String text) async {
    final out = await _ch.invokeMethod<String>('fix', {
      'modelDir': modelDir,
      'encoder': encoder,
      'decoder': decoder,
      'threads': threads,
      'text': text,
    });
    if (out == null || out.isEmpty) return text;
    // guard 1: corretor nao dobra o tamanho; se dobrou, degenerou -> original
    if (out.length > text.length * 2 + 20) return text;
    // guard 2: degenerou em laco (mesmo trecho de 2-6 chars repetido) -> original
    if (RegExp(r'(.{2,6})\1').hasMatch(out)) return text;
    return out;
  }

  @override
  Future<List<SrtCue>> auditJa(List<SrtCue> cues,
      {bool Function()? isCancelled}) async {
    final out = <SrtCue>[];
    for (final c in cues) {
      if (isCancelled?.call() ?? false) return cues;
      final t = await fix(c.text);
      out.add(c.withText(t));
    }
    return out;
  }

  /// Este auditor é só JA (pré-tradução). O passe PT não se aplica — devolve
  /// as cues sem tocar (um auditor PT separado cuidaria disso).
  @override
  Future<List<SrtCue>> auditPt(List<SrtCue> cues,
          {bool Function()? isCancelled}) async =>
      cues;

  @override
  Future<void> dispose() => _ch.invokeMethod('dispose');
}
