import 'package:flutter/services.dart';

/// Wrapper do `AudioExtractChannel` Kotlin (MediaExtractor/MediaCodec).
/// Sem ffmpeg-kit. Usado na Rota S (tracks embutidas) e Fase 2 (PCM 16k).
class AudioExtract {
  static const _ch = MethodChannel('goanime_tv/audio_extract');

  static Future<List<SubtitleTrackInfo>> getSubtitleTracks({
    String? url,
    String? path,
    Map<String, String> headers = const {},
  }) async {
    final res = await _ch.invokeMethod('getSubtitleTracks',
        {'url': url, 'path': path, 'headers': headers});
    return (res as List)
        .map((e) => SubtitleTrackInfo.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  static Future<String> extractPcm16k({
    String? url,
    String? path,
    Map<String, String> headers = const {},
    required String outPath,
  }) async {
    final res = await _ch.invokeMethod('extractPcm16k',
        {'url': url, 'path': path, 'headers': headers, 'outPath': outPath});
    return (res as Map)['pcmPath'] as String;
  }

  static Future<void> cancel() => _ch.invokeMethod('cancel');
}

class SubtitleTrackInfo {
  final int index;
  final String mime;
  final String? language;
  const SubtitleTrackInfo({required this.index, required this.mime, this.language});

  factory SubtitleTrackInfo.fromMap(Map<String, dynamic> m) => SubtitleTrackInfo(
        index: (m['index'] as num).toInt(),
        mime: m['mime'] as String,
        language: m['language'] as String?,
      );
}
