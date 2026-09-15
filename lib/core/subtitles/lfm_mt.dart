import 'package:flutter/services.dart';

import 'mt_provider.dart';

/// Canal do tradutor LFM2 Kotlin (injetável p/ teste sem nativo).
abstract class LfmChannel {
  Future<String> translate(String modelDir, String text,
      {required String srcLang, required String tgtLang});
  Future<void> dispose();
}

class MethodLfmChannel implements LfmChannel {
  static const _ch = MethodChannel('goanime_tv/lfm');

  @override
  Future<String> translate(String modelDir, String text,
      {required String srcLang, required String tgtLang}) async {
    final out = await _ch.invokeMethod<String>('translate', {
      'modelDir': modelDir,
      'text': text,
      'srcLang': srcLang,
      'tgtLang': tgtLang,
    });
    return out ?? '';
  }

  @override
  Future<void> dispose() => _ch.invokeMethod('dispose');
}

/// MT LFM2-350M-ENJP-MT q4f16 (JA↔EN dedicado, causal com cache).
/// Sessão Kotlin cacheada; [dispose] descarrega (carga sequencial).
/// Cobre o buraco do L1: STT transcreve JA (base) → LFM JA→EN → Marian EN→PT.
class LfmMtProvider extends MtProvider {
  final String modelDir;
  final LfmChannel? channelForTest;
  /// LFM é maior que Marian (prefill 350M/frase): teto 10 min.
  final Duration translateTimeout;
  LfmChannel? _ch;
  bool _loaded = false;

  LfmMtProvider(this.modelDir,
      {this.channelForTest,
      this.translateTimeout = const Duration(minutes: 10)});

  @override
  String get id => 'lfm-ja-en';

  @override
  Future<void> load() async {
    _ch = channelForTest ?? MethodLfmChannel();
    _loaded = true;
  }

  static final _sentSplit = RegExp(r'(?<=[.!?…])\s+');

  static String _lfmCode(String lang) => switch (lang) {
        'ja' => 'ja',
        'en' => 'en',
        _ => throw StateError('LFM só traduz JA↔EN (pedido $lang)'),
      };

  @override
  Future<String> translate(String text,
      {required String src, required String tgt}) async {
    final ch = _ch;
    if (!_loaded || ch == null) {
      throw StateError('LfmMtProvider.load() antes de translate()');
    }
    final srcCode = _lfmCode(src);
    final tgtCode = _lfmCode(tgt);
    if (srcCode == tgtCode) return text;
    final parts = text.split(_sentSplit).where((s) => s.trim().isNotEmpty);
    final out = <String>[];
    for (final p in parts) {
      out.add(await ch
          .translate(modelDir, p.trim(), srcLang: srcCode, tgtLang: tgtCode)
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

  static String get modelId => 'lfm-ja-en';
}
