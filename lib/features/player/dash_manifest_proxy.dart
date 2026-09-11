import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Local DASH manifest proxy for AnimeFire streams.
///
/// Two problems, one fix:
///
/// 1. The CDN serves the MPD as `/m.jpg` (`content-type: application/dash+xml`).
///    The player fails at demux-open on that URL (`Failed to open`, dur=0).
///    Re-serving the same document from loopback with an `.mpd` extension
///    and a `dash+xml` content-type opens normally.
/// 2. One manifest carries every quality (480p/720p/1080p as Representations),
///    so a single URL can't express "play 720p". With [height] set, the proxy
///    serves the manifest filtered to that Representation (+ the audio set),
///    which is what makes per-quality buttons real instead of placebo.
///
/// Segment URLs in the source MPD are root-relative (`/i/...`); they are
/// rewritten to absolute CDN URLs, so the player fetches media straight from
/// the CDN — only the manifest itself flows through loopback (cleartext to
/// 127.0.0.1 is allowed by Android without extra config).
///
/// Scope: AnimeFire only, instantiated per [PlayerScreen] and closed on
/// dispose. Any fetch/rewrite failure must make the caller fall back to the
/// direct URL (never fail playback that might have worked).
class DashManifestProxy {
  DashManifestProxy({http.Client? client}) : _client = client;

  final http.Client? _client;
  HttpServer? _server;
  final _docs = <String, String>{};
  var _counter = 0;

  /// Codecs das Representations de vídeo do último manifesto servido
  /// (ex. `{'av01.0.08M.08'}`). Vazio quando o MPD não declara `codecs`
  /// — o chamador trata como desconhecido (fail-open, tenta tocar).
  Set<String> lastVideoCodecs = const {};

  /// Fetches [manifestUrl], rewrites it ([rewriteManifest]) and serves it as
  /// `/af-<n>.mpd`. [height] selects the video Representation (matched by its
  /// `height` attribute); null serves the full adaptive manifest.
  Future<Uri> serveManifest({
    required String manifestUrl,
    int? height,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse(manifestUrl);
    final res = _client != null
        ? await _client.get(uri, headers: headers)
        : await http.get(uri, headers: headers);
    if (res.statusCode != 200) {
      throw HttpException('Manifest fetch failed: ${res.statusCode}');
    }
    lastVideoCodecs = videoCodecs(mpd: res.body);
    final doc = rewriteManifest(mpd: res.body, base: uri, height: height);
    final server = _server ??= await _serve();
    final path = '/af-${_counter++}.mpd';
    _docs[path] = doc;
    return Uri.parse('http://127.0.0.1:${server.port}$path');
  }

  Future<HttpServer> _serve() async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    debugPrint('[DashProxy] listening on 127.0.0.1:${server.port}');
    server.listen((req) async {
      try {
        final doc = _docs[req.uri.path];
        if (doc == null) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        // Bytes + Content-Length explícito: o demuxer DASH do ffmpeg relê o
        // manifesto e falha sobre chunked sem tamanho ("Unable to read
        // manifest" / "Failed to recognize file format"). Nunca use
        // String.length aqui (UTF-8 multi-byte, ex. "Português").
        final body = utf8.encode(doc);
        req.response.headers.contentType =
            ContentType.parse('application/dash+xml');
        req.response.headers.set('Accept-Ranges', 'bytes');
        req.response.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
      } catch (e) {
        debugPrint('[DashProxy] serve error: $e');
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
    return server;
  }

  Future<void> close() async {
    _docs.clear();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// Pure rewrite: absolutizes root-relative segment URLs and, when [height]
  /// is set, drops video Representations of any other height (audio sets have
  /// no `height` attribute and are never touched). No match → full manifest.
  @visibleForTesting
  static String rewriteManifest({
    required String mpd,
    required Uri base,
    int? height,
  }) {
    var out = _absolutize(mpd, base);
    if (height == null) return out;
    final repRe = RegExp(
      r'<Representation\b[^>]*\bheight="(\d+)"[^>]*>.*?</Representation>',
      dotAll: true,
    );
    final matches = repRe.allMatches(out).toList();
    if (!matches.any((m) => int.tryParse(m.group(1) ?? '') == height)) {
      return out;
    }
    var bestBandwidth = -1;
    for (final m in matches) {
      if (int.tryParse(m.group(1) ?? '') != height) continue;
      final bw = int.tryParse(
            RegExp(r'bandwidth="(\d+)"').firstMatch(m.group(0) ?? '')?.group(1) ??
                '',
          ) ??
          -1;
      if (bw > bestBandwidth) bestBandwidth = bw;
    }
    final buf = StringBuffer();
    var cursor = 0;
    for (final m in matches) {
      final h = int.tryParse(m.group(1) ?? '');
      final bw = int.tryParse(
            RegExp(r'bandwidth="(\d+)"').firstMatch(m.group(0) ?? '')?.group(1) ??
                '',
          ) ??
          -1;
      final keep = h == height && (bestBandwidth < 0 || bw >= bestBandwidth);
      if (keep) continue;
      buf.write(out.substring(cursor, m.start));
      cursor = m.end;
    }
    buf.write(out.substring(cursor));
    return buf.toString();
  }

  /// Codecs das Representations de vídeo (`mimeType="video..."`) do MPD.
  /// Só o que o proxy precisa saber: se tudo é `av01`, um aparelho sem
  /// decoder AV1 toca som sobre tela preta — o player avisa em vez disso.
  @visibleForTesting
  static Set<String> videoCodecs({required String mpd}) {
    final out = <String>{};
    final repRe = RegExp(r'<Representation\b[^>]*>', dotAll: true);
    for (final m in repRe.allMatches(mpd)) {
      final tag = m.group(0)!;
      if (!tag.contains('mimeType="video')) continue;
      final c =
          RegExp(r'codecs="([^"]+)"').firstMatch(tag)?.group(1);
      if (c != null && c.isNotEmpty) out.add(c);
    }
    return out;
  }

  /// True quando o manifesto declara vídeo e é tudo AV1.
  static bool isAv1Only(Set<String> codecs) =>
      codecs.isNotEmpty && codecs.every((c) => c.startsWith('av01'));

  static String _absolutize(String mpd, Uri base) {
    final origin = base.origin;
    var out = mpd.replaceAllMapped(
      RegExp(r'(media|initialization)="(/[^"/][^"]*)"'),
      (m) => '${m.group(1)}="$origin${m.group(2)}"',
    );
    out = out.replaceAllMapped(
      RegExp(r'<BaseURL>(/[^<]*)</BaseURL>'),
      (m) => '<BaseURL>$origin${m.group(1)}</BaseURL>',
    );
    return out;
  }
}
