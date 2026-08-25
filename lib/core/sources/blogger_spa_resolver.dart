import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../data/models/episode.dart';
import 'cdn_resolver.dart' show probeMediaUrl;
import 'dooplay_v2_extractor.dart' show DooPlayV2Extractor;

/// Resolves Blogger SPA video embeds into playable streams.
///
/// Several DooPlay sites (BetterAnime, AnimesOnline HDK, AnimesHD, Animes
/// Orion) answer their player API with a Blogger embed:
///
///  - `https://www.blogger.com/video.g?token=AD6v5…` (direct), or
///  - a `jwplayer/?source=<base64>&type=blogger` wrapper whose `source`,
///    when base64-decoded and reversed, is that same `video.g` URL.
///
/// Blogger shut down public video hosting, so most tokens 404 — the sites
/// keep serving the dead links and the stream is unrecoverable. This resolver
/// still walks the WHOLE chain deterministically and only yields a
/// [VideoSource] when a URL answers a 206 range probe:
///
///  1. direct mp4/m3u8 already present in the embed (`source=` param);
///  2. blogger token extracted from the embed (base64-reverse when wrapped);
///  3. known Blogger/Google direct endpoints probed with that token
///     (`video-play.mp4?contentID=`, `redirector.googlevideo.com`);
///  4. the `video.g` SPA page fetched and scanned for media URLs (including
///     `\uXXXX`-escaped JSON strings).
///
/// Callers turn the empty result into [BloggerUnsupportedError]: the episode
/// exists on the source, it just can't deliver a video.
class BloggerSpaResolver {
  BloggerSpaResolver({http.Client? client}) : _client = client;

  final http.Client? _client;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, '
      'like Gecko) Chrome/124.0 Safari/537.36';

  static const _probeTimeout = Duration(seconds: 15);

  /// Returns the playable streams for a Blogger embed, or an empty list when
  /// nothing answers the range probe (dead token / SPA without a media URL).
  Future<List<VideoSource>> resolve({
    required String embedUrl,
    required String referer,
  }) async {
    // 1. The embed may already carry a direct mp4/m3u8.
    final direct = DooPlayV2Extractor.mp4FromEmbed(embedUrl);
    if (direct != null && await _probe(direct, referer) >= 0) {
      return [_source(direct, referer)];
    }

    // 2. Blogger token → direct endpoints + SPA scan.
    final token = _extractBloggerToken(embedUrl);
    if (token == null) return const [];

    final viaEndpoint = await _probeEndpoints(token, referer);
    if (viaEndpoint != null) return [_source(viaEndpoint, referer)];

    final spa = await _fetchSpa(token, referer);
    if (spa == null) return const [];
    final spaUrl = _scanMediaUrl(spa);
    if (spaUrl != null && await _probe(spaUrl, referer) >= 0) {
      return [_source(spaUrl, referer)];
    }
    return const [];
  }

  /// Extracts the opaque Blogger `token` (the `AD6v5…` value) from an embed.
  /// Handles both the direct `video.g?token=` form and the DooPlay
  /// `jwplayer/?source=<base64>` wrapper (base64 → reversed → video.g URL).
  static String? _extractBloggerToken(String embedUrl) {
    final u = Uri.tryParse(embedUrl);
    if (u == null) return null;

    final source = u.queryParameters['source'];
    if (source != null && source.isNotEmpty) {
      final decoded = _base64Decode(source);
      if (decoded != null && decoded.isNotEmpty) {
        final reversed = decoded.split('').reversed.join();
        final tok = _tokenFromUrl(reversed);
        if (tok != null) return tok;
      }
    }
    return _tokenFromUrl(embedUrl);
  }

  static String? _tokenFromUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    if (!u.host.contains('blogger') && !u.path.contains('video')) return null;
    final token = u.queryParameters['token'];
    if (token != null && token.isNotEmpty) return token;
    return u.queryParameters['contentID'] ?? u.queryParameters['video_id'];
  }

  static String? _base64Decode(String raw) {
    try {
      final b = raw.replaceAll(' ', '+');
      final padded = b + '=' * (-b.length % 4);
      return utf8.decode(base64.decode(padded), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Probes the known Blogger/Google direct endpoints for a token.
  Future<String?> _probeEndpoints(String token, String referer) async {
    final enc = Uri.encodeComponent(token);
    for (final url in [
      'https://www.blogger.com/video-play.mp4?contentID=$enc',
      'https://redirector.googlevideo.com/videoplayback?video_id=$enc',
    ]) {
      if (await _probe(url, referer) >= 0) return url;
    }
    return null;
  }

  Future<String?> _fetchSpa(String token, String referer) async {
    try {
      final uri =
          Uri.parse('https://www.blogger.com/video.g?token=${Uri.encodeComponent(token)}');
      final res = _client != null
          ? await _client.get(uri, headers: _headers(referer))
          : await http.get(uri, headers: _headers(referer)).timeout(_probeTimeout);
      if (res.statusCode != 200) return null;
      return res.body;
    } catch (_) {
      return null;
    }
  }

  /// Scans the SPA page for a media URL. Blogger escapes JSON strings with
  /// `\u0026`/`\/`, so the scan runs over a de-escaped copy and accepts both
  /// `.mp4`/`.m3u8` files and Google `videoplayback` routes, keeping any query
  /// string that follows the file extension.
  static String? _scanMediaUrl(String spaHtml) {
    final unescaped = spaHtml
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\/', '/')
        .replaceAll('\\u003d', '=');
    final m = RegExp(
      r'''https?://[^"'\s<>\\]+(?:\.mp4|\.m3u8|/videoplayback)[^"'\s<>\\]*''',
    ).firstMatch(unescaped);
    return m?.group(0);
  }

  Future<int> _probe(String url, String referer) {
    return probeMediaUrl(Uri.parse(url), client: _client, headers: _headers(referer));
  }

  Map<String, String> _headers(String referer) => {
        'User-Agent': _ua,
        'Referer': referer,
      };

  VideoSource _source(String url, String referer) => VideoSource(
        url: url,
        quality: 'Auto',
        headers: _headers(referer),
      );
}