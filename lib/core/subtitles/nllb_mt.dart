import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/device_capability.dart';
import 'mt_provider.dart';
import 'srt_parser.dart';

/// Gating L2 (plano §L2): `!isLowEnd + disco > 2GB`. Valores injetáveis p/ teste.
class AiCapability {
  static const nllbMinFreeBytes = 2 * 1024 * 1024 * 1024;

  final Future<bool> Function()? isLowEndForTest;
  final Future<int> Function()? freeBytesForTest;
  const AiCapability({this.isLowEndForTest, this.freeBytesForTest});

  Future<bool> canUseFull() async {
    final low =
        isLowEndForTest != null ? await isLowEndForTest!() : await DeviceCapability.isLowEnd();
    if (low) return false;
    final free = freeBytesForTest != null
        ? await freeBytesForTest!()
        : await _diskFree();
    return free > nllbMinFreeBytes;
  }

  Future<int> _diskFree() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final bytes = await const MethodChannel('goanime_tv/audio_extract')
          .invokeMethod<int>('freeSpaceBytes', {'path': dir.path});
      return bytes ?? 0;
    } catch (_) {
      return 0; // fail-closed: sem info de disco, L2 bloqueado
    }
  }

  static const instance = AiCapability();
}

/// Canal do tradutor NLLB Kotlin (injetável p/ teste sem nativo).
abstract class NllbChannel {
  Future<String> translate(String modelDir, String text,
      {required String srcLang, required String tgtLang});
  Future<void> dispose();
}

class MethodNllbChannel implements NllbChannel {
  static const _ch = MethodChannel('goanime_tv/nllb');

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

/// MT L2 NLLB-600M int8 (jpn→por direto, sem pivô em inglês).
/// Sessão Kotlin cacheada; [dispose] descarrega (carga sequencial).
class NllbMtProvider extends MtProvider {
  final String modelDir;
  final NllbChannel? channelForTest;
  final AiCapability? capabilityForTest;
  NllbChannel? _ch;
  bool _loaded = false;

  NllbMtProvider(this.modelDir, {this.channelForTest, this.capabilityForTest});

  @override
  String get id => 'nllb';

  @override
  Future<void> load() async {
    final cap = capabilityForTest ?? AiCapability.instance;
    if (!await cap.canUseFull()) {
      throw StateError('NLLB exige aparelho forte + 2GB livres');
    }
    _ch = channelForTest ?? MethodNllbChannel();
    _loaded = true;
  }

  static final _sentSplit = RegExp(r'(?<=[.!?…])\s+');

  @override
  Future<String> translate(String text,
      {required String src, required String tgt}) async {
    final ch = _ch;
    if (!_loaded || ch == null) {
      throw StateError('NllbMtProvider.load() antes de translate()');
    }
    final parts = text.split(_sentSplit).where((s) => s.trim().isNotEmpty);
    final out = <String>[];
    for (final p in parts) {
      out.add(await ch.translate(modelDir, p.trim(),
          srcLang: _nllbCode(src), tgtLang: _nllbCode(tgt)));
    }
    return out.join(' ');
  }

  static String _nllbCode(String lang) => switch (lang) {
        'ja' => 'jpn_Jpan',
        'pt' => 'por_Latn',
        'en' => 'eng_Latn',
        'es' => 'spa_Latn',
        _ => 'eng_Latn',
      };

  Future<String> translateSrt(String srcSrt,
      {required String src, required String tgt}) async {
    final cues = SrtParser.parse(srcSrt);
    return SrtParser.format(await translateCues(cues, src: src, tgt: tgt));
  }

  @override
  Future<void> dispose() async {
    try {
      await _ch?.dispose();
    } catch (_) {}
    _ch = null;
    _loaded = false;
  }

  /// Espaço ocupado pelos modelos NLLB (Settings). Reuso: AudioExtract não
  /// mede árvore; ModelManager.usedBytes cobre — este helper só documenta.
  static String get modelId => 'nllb-600M-int8';
}
