import 'package:flutter/services.dart';

import 'mt_provider.dart';
import 'srt_parser.dart';

/// Canal do tradutor Marian Kotlin (injetável p/ teste sem nativo).
abstract class MarianChannel {
  Future<String> translate(String modelDir, String text,
      {String? targetPrefix});
  Future<void> dispose();
}

class MethodMarianChannel implements MarianChannel {
  static const _ch = MethodChannel('goanime_tv/marian');

  @override
  Future<String> translate(String modelDir, String text,
      {String? targetPrefix}) async {
    final out = await _ch.invokeMethod<String>('translate', {
      'modelDir': modelDir,
      'text': text,
      'targetPrefix': targetPrefix,
    });
    return out ?? '';
  }

  @override
  Future<void> dispose() => _ch.invokeMethod('dispose');
}

/// Tradução EN/ES→PT leve (Marian opus-mt-en-mul int8, beam 1 = greedy),
/// chunk por frase. Inferência no Kotlin via ORT Android; o plugin Dart
/// `onnxruntime` foi removido de propósito (template compileSdk 33 quebrava
/// o AAR metadata check do build release).
/// `targetPrefix`: `>>por<<` no modelo multilíngue; null = unidirecional.
/// Carga sequencial: [dispose] antes de subir outro provider.
class MarianMtProvider extends MtProvider {
  final String modelDir;
  final String? targetPrefix;
  final MarianChannel? channelForTest;
  /// Teto por frase: thread nativa morta vira job falho com mensagem em vez
  /// de hang eterno (a 1ª frase inclui o load das 2 sessões ORT).
  final Duration translateTimeout;
  MarianChannel? _ch;
  bool _loaded = false;

  MarianMtProvider(this.modelDir,
      {this.targetPrefix,
      this.channelForTest,
      this.translateTimeout = const Duration(minutes: 5)});

  @override
  String get id => 'marian';

  @override
  Future<void> load() async {
    _ch = channelForTest ?? MethodMarianChannel();
    _loaded = true;
  }

  static final _sentSplit = RegExp(r'(?<=[.!?…])\s+');

  @override
  Future<String> translate(String text,
      {required String src, required String tgt}) async {
    final ch = _ch;
    if (!_loaded || ch == null) {
      throw StateError('MarianMtProvider.load() antes de translate()');
    }
    final parts = text.split(_sentSplit).where((s) => s.trim().isNotEmpty);
    final out = <String>[];
    for (final p in parts) {
      out.add(await ch
          .translate(modelDir, p.trim(), targetPrefix: targetPrefix)
          .timeout(translateTimeout, onTimeout: () {
        throw StateError(
            'Tradução travou (timeout ${translateTimeout.inMinutes} min). '
            'Aparelho sem memória? Tente de novo.');
      }));
    }
    return out.join(' ');
  }

  /// Cache hit não retraduz (Rota S): traduz o .srt fonte e salva via store.
  Future<String> translateSrt(String srcSrt,
      {required String src, required String tgt}) async {
    final cues = SrtParser.parse(srcSrt);
    return SrtParser.format(
        await translateCues(cues, src: src, tgt: tgt));
  }

  @override
  Future<void> dispose() async {
    try {
      await _ch?.dispose();
    } catch (_) {}
    _ch = null;
    _loaded = false;
  }
}
