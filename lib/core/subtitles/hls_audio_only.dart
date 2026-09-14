import 'dart:convert';
import 'dart:io';

/// Download só-áudio de HLS (equivale ao `bestaudio` do yt-dlp): quando o
/// manifesto expõe grupo `EXT-X-MEDIA:TYPE=AUDIO`, baixa só os segmentos de
/// áudio (~15 MB p/ 24 min em vez de ~140 MB do mp4 cheio) e concatena num
/// arquivo local p/ o `extractPcm16k` (MediaExtractor demuxa AAC/TS).
/// Retorna null quando não há faixa separada (mp4 único, DASH, AES-128,
/// BYTERANGE) → o chamador cai p/ o download do vídeo completo.
/// `fetchForTest` injeta corpos por URL p/ teste sem rede.
class HlsAudioOnly {
  const HlsAudioOnly._();

  static final _media =
      RegExp(r'#EXT-X-MEDIA:TYPE=AUDIO[^\n]*URI="([^"]+)"');
  static final _map = RegExp(r'#EXT-X-MAP:[^\n]*URI="([^"]+)"');
  static final _key = RegExp(r'#EXT-X-KEY:[^\n]*');

  /// Resolve a playlist de áudio; null se indisponível.
  static Future<Uri?> audioPlaylistUri(
    String masterUrl, {
    Map<String, String> headers = const {},
    Future<String> Function(Uri url)? fetchForTest,
  }) async {
    if (!masterUrl.toLowerCase().contains('.m3u8')) return null;
    try {
      final masterUri = Uri.parse(masterUrl);
      final body = fetchForTest != null
          ? await fetchForTest(masterUri)
          : await _get(masterUri, headers);
      final m = _media.firstMatch(body);
      if (m == null) return null;
      return masterUri.resolve(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// Baixa segmentos de áudio p/ [outPath]. Retorna null se a playlist
  /// exigir AES-128 ou BYTERANGE (fora do escopo → fallback vídeo).
  static Future<File?> fetch(
    Uri playlistUri,
    File outPath, {
    Map<String, String> headers = const {},
    Future<String> Function(Uri url)? fetchForTest,
    Future<List<int>> Function(Uri url)? fetchBytesForTest,
    void Function(int gotBytes)? onProgress,
  }) async {
    try {
      final body = fetchForTest != null
          ? await fetchForTest(playlistUri)
          : await _get(playlistUri, headers);
      if (_key.hasMatch(body)) return null; // AES-128: fora
      final lines = body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      final parts = <Uri>[];
      for (final l in lines) {
        if (l.startsWith('#')) {
          if (l.contains('EXT-X-BYTERANGE')) return null; // fora
          final mm = _map.firstMatch(l);
          if (mm != null) parts.add(playlistUri.resolve(mm.group(1)!));
          continue;
        }
        parts.add(playlistUri.resolve(l));
      }
      if (parts.isEmpty) return null;
      await outPath.parent.create(recursive: true);
      final sink = outPath.openWrite();
      var got = 0;
      try {
        for (final u in parts) {
          final bytes = fetchBytesForTest != null
              ? await fetchBytesForTest(u)
              : await _getBytes(u, headers);
          sink.add(bytes);
          got += bytes.length;
          onProgress?.call(got);
        }
      } finally {
        await sink.close();
      }
      return outPath;
    } catch (_) {
      try {
        await outPath.delete();
      } catch (_) {}
      return null;
    }
  }

  static Future<String> _get(Uri uri, Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      headers.forEach(req.headers.set);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      return await resp.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 15));
    } finally {
      client.close();
    }
  }

  static Future<List<int>> _getBytes(
      Uri uri, Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      headers.forEach(req.headers.set);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final out = <int>[];
      await for (final chunk in resp) {
        out.addAll(chunk);
      }
      return out;
    } finally {
      client.close();
    }
  }
}
