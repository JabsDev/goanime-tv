import 'dart:io';

import 'package:flutter/services.dart';

import 'model_manager.dart';
import 'mt_provider.dart';

/// Canal do tradutor llama.cpp Kotlin (injetável p/ teste sem nativo).
abstract class LlmChannel {
  Future<String> translate(String modelPath, String text,
      {required String srcLang, required String tgtLang});
  Future<void> dispose();
}

class MethodLlmChannel implements LlmChannel {
  static const _ch = MethodChannel('goanime_tv/llm');

  @override
  Future<String> translate(String modelPath, String text,
      {required String srcLang, required String tgtLang}) async {
    final out = await _ch.invokeMethod<String>('translate', {
      'modelPath': modelPath,
      'text': text,
      'srcLang': srcLang,
      'tgtLang': tgtLang,
    });
    return out ?? '';
  }

  @override
  Future<void> dispose() => _ch.invokeMethod('dispose');
}

/// MT Hy-MT2-1.8B via llama.cpp (GGUF, JA→PT direto + EN→PT).
/// Sessão nativa cacheada; [dispose] descarrega (carga sequencial com STT).
class LlmMtProvider extends MtProvider {
  final String modelPath;
  final LlmChannel? channelForTest;
  /// Tamanho esperado (MB) p/ validar o GGUF no load; injetado pelo
  /// catálogo via AiProviders (fallback inferido pelo nome do dir).
  final int? expectedMb;
  /// LLM é lento por frase (pior no stick): teto 10 min.
  final Duration translateTimeout;
  LlmChannel? _ch;
  bool _loaded = false;

  LlmMtProvider(this.modelPath,
      {this.channelForTest,
      this.expectedMb,
      this.translateTimeout = const Duration(minutes: 10)});

  @override
  String get id => 'hymt-llm';

  @override
  Future<void> load() async {
    // Fail-fast: GGUF truncado falhava só na 1ª frase (depois de baixar
    // vídeo/transcrever). Só valida no aparelho real (teste usa fake path).
    if (channelForTest == null) {
      final mb = expectedMb ?? _inferMb();
      if (!await ModelManager.isValidGguf(File(modelPath), mb)) {
        throw StateError('LLM_CORRUPT: $modelPath');
      }
    }
    _ch = channelForTest ?? MethodLlmChannel();
    _loaded = true;
  }

  int _inferMb() {
    try {
      final dir = File(modelPath).parent.path.split('/').last;
      final mb = aiModelCatalog[dir]?.mb;
      if (mb != null) return mb;
    } catch (_) {}
    return 850; // fallback p/ construção avulsa fora do catálogo
  }

  static final _sentSplit = RegExp(r'(?<=[.!?…])\s+');

  /// Peça única nunca passa de ~500 chars (~360 tokens JA): cabe folgada
  /// no contexto sem truncar. Sem isto, alucinação longa do STT ia inteira
  /// num batch e o nativo abortava (SIGABRT do EP3).
  static const maxPieceChars = 500;
  static final _pieceCut = RegExp(r'[、，,．.\s]');

  static Iterable<String> pieces(String text) sync* {
    for (final s in text.split(_sentSplit).map((s) => s.trim()).where(
        (s) => s.isNotEmpty)) {
      if (s.length <= maxPieceChars) {
        yield s;
        continue;
      }
      var start = 0;
      while (start < s.length) {
        var end = (start + maxPieceChars).clamp(0, s.length);
        if (end < s.length) {
          final cut = s.lastIndexOf(_pieceCut, end);
          if (cut > start) end = cut + 1;
        }
        final piece = s.substring(start, end).trim();
        if (piece.isNotEmpty) yield piece;
        if (end <= start) break; // sem âncora: nunca gira parado
        start = end;
      }
    }
  }

  static String _llmCode(String lang) => switch (lang) {
        'ja' => 'ja',
        'en' => 'en',
        'pt' => 'pt',
        'es' => 'es',
        _ => throw StateError('LLM sem par p/ "$lang" (só ja/en/pt/es)'),
      };

  @override
  Future<String> translate(String text,
      {required String src, required String tgt}) async {
    final ch = _ch;
    if (!_loaded || ch == null) {
      throw StateError('LlmMtProvider.load() antes de translate()');
    }
    final srcCode = _llmCode(src);
    final tgtCode = _llmCode(tgt);
    if (srcCode == tgtCode) return text;
    final parts = pieces(text);
    final out = <String>[];
    for (final p in parts) {
      out.add(await ch
          .translate(modelPath, p.trim(), srcLang: srcCode, tgtLang: tgtCode)
          .timeout(translateTimeout, onTimeout: () {
        throw StateError(
            'Tradução travou (timeout ${translateTimeout.inMinutes} min). '
            'Aparelho sem memória? Tente de novo.');
      }));
    }
    return out.join(' ');
  }

  @override
  Future<void> dispose() async {
    try {
      await _ch?.dispose();
    } catch (_) {}
    _ch = null;
    _loaded = false;
  }

  static String get modelIdQ3 => 'hymt-ja-pt-q3km';
  static String get modelIdQ4 => 'hymt-ja-pt-q4';
}
