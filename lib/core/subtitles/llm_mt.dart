import 'package:flutter/services.dart';

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
  /// LLM é lento por frase (pior no stick): teto 10 min.
  final Duration translateTimeout;
  LlmChannel? _ch;
  bool _loaded = false;

  LlmMtProvider(this.modelPath,
      {this.channelForTest,
      this.translateTimeout = const Duration(minutes: 10)});

  @override
  String get id => 'hymt-llm';

  @override
  Future<void> load() async {
    _ch = channelForTest ?? MethodLlmChannel();
    _loaded = true;
  }

  static final _sentSplit = RegExp(r'(?<=[.!?…])\s+');

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
    final parts = text.split(_sentSplit).where((s) => s.trim().isNotEmpty);
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
