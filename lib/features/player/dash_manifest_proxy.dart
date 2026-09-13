import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Local manifest proxy for AnimeFire streams.
///
/// Two problems, one fix:
///
/// 1. The CDN serves manifests as `*.jpg` (`/m.jpg` = DASH `dash+xml`,
///    `/h.jpg` = HLS `#EXTM3U` — the format varies per episode). Players
///    sniff by extension, so the proxy re-serves the same document from
///    loopback with the right extension (`.mpd` / `.m3u8`) and content-type.
/// 2. One manifest carries every quality (DASH Representations / HLS
///    variants), so a single URL can't express "play 720p". With [height]
///    set, the proxy serves the manifest filtered to that height (+ the
///    audio), which is what makes per-quality buttons real instead of
///    placebo.
///
/// Relative segment/variant URLs are rewritten to absolute CDN URLs, so the
/// player fetches media straight from the CDN — only the manifest itself
/// flows through loopback (cleartext to 127.0.0.1 is allowed by Android
/// without extra config).
///
/// Exception: HLS sub-resources (variant playlists + segments). The player's
/// own HTTP client (ffmpeg/Lavf in mpv) fetches those directly, with its own
/// UA/TLS fingerprint — and the CDN refused exactly that on-device ("Failed
/// to open" the variant playlist while the app's fetch works). So HLS
/// variants/segments are re-pointed at loopback and forwarded by the proxy
/// with the app's headers: the player never touches the CDN.
///
/// Scope: AnimeFire only, instantiated per player screen and closed on
/// dispose. Any fetch/rewrite failure must make the caller fall back to the
/// direct URL (never fail playback that might have worked).
class DashManifestProxy {
  DashManifestProxy({http.Client? client}) : _client = client;

  final http.Client? _client;
  HttpServer? _server;
  final _docs = <String, String>{};
  final _upstream = <String, _Upstream>{};
  var _counter = 0;

  /// Codecs de vídeo do último manifesto servido (ex. `{'av01.0.08M.08'}`).
  /// Vazio quando o manifesto não declara codecs — o chamador trata como
  /// desconhecido (fail-open, tenta tocar).
  Set<String> lastVideoCodecs = const {};

  /// True quando o último manifesto servido era HLS (`#EXTM3U`).
  /// O chamador usa para hints de demuxer (mpv só força `dash` no DASH).
  bool lastIsHls = false;

  /// Fetches [manifestUrl], rewrites it and serves it as `/af-<n>.mpd` (DASH)
  /// or `/af-<n>.m3u8` (HLS). [height] selects the video
  /// Representation/variant (matched by height); null serves the full
  /// adaptive manifest.
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
    lastIsHls = isHls(body: res.body);
    lastVideoCodecs = videoCodecs(body: res.body);
    final server = _server ??= await _serve();
    final tag = _counter++;
    if (!lastIsHls) {
      final doc = rewriteManifest(mpd: res.body, base: uri, height: height);
      final path = '/af-$tag.mpd';
      _docs[path] = doc;
      return Uri.parse('http://127.0.0.1:${server.port}$path');
    }
    // HLS: absolutiza + filtra a altura (URLs do CDN), depois troca as
    // variantes por loopback (full-chain: o player nunca toca no CDN).
    var doc = rewriteHls(playlist: res.body, base: uri, height: height);
    doc = _swapToLoopback(doc, tag, headers, bareAreVariants: true);
    final path = '/af-$tag.m3u8';
    _docs[path] = doc;
    return Uri.parse('http://127.0.0.1:${server.port}$path');
  }

  /// Troca URIs absolutas do CDN por loopback, registrando o upstream para
  /// busca sob demanda no handler. [bareAreVariants]: no master, linhas
  /// soltas são variant playlists; nas sub-playlists, são segmentos.
  /// `URI="..."` (EXT-X-MEDIA/KEY/MAP) é sempre sub-playlist/mídia relativa
  /// ao contexto — registrada como variante (parse de media playlist serve
  /// para ambas: sem STREAM-INF, só absolutiza).
  String _swapToLoopback(
    String doc,
    int tag,
    Map<String, String> headers, {
    required bool bareAreVariants,
  }) {
    var v = 0;
    var s = 0;
    final lines = doc.split('\n');
    final out = lines.map((line) {
      final t = line.trimRight();
      if (t.isEmpty) return line;
      if (!t.startsWith('#')) {
        if (!t.startsWith('http://') && !t.startsWith('https://')) return line;
        // Segmentos com extensão `.m4s`: o demuxer HLS do ffmpeg (mpv)
        // rejeita URLs sem extensão (`allowed_segment_extensions`) — sem
        // isso, "Failed to open" mesmo com os bytes corretos. O conteúdo
        // é fmp4, farejado pelo demuxer mov; ExoPlayer ignora a extensão.
        final p = bareAreVariants
            ? '/af-${tag}v${v++}.m3u8'
            : '/af-$tag-s${s++}.m4s';
        _upstream[p] = _Upstream(t, headers, isVariant: bareAreVariants);
        return p;
      }
      return t.replaceAllMapped(
        RegExp('URI="([^"]+)"'),
        (m) {
          final target = m.group(1)!;
          if (target.startsWith('http://') || target.startsWith('https://')) {
            // Mesmo contexto das linhas soltas: no master (EXT-X-MEDIA) é
            // sub-playlist; na mídia (EXT-X-MAP/KEY) é bytes (init/key).
            final p = bareAreVariants
                ? '/af-${tag}v${v++}.m3u8'
                : '/af-$tag-s${s++}.m4s';
            _upstream[p] =
                _Upstream(target, headers, isVariant: bareAreVariants);
            return 'URI="$p"';
          }
          return m.group(0)!;
        },
      );
    }).join('\n');
    return out;
  }

  Future<http.Response> _fetchUpstream(_Upstream up) {
    final uri = Uri.parse(up.url);
    final fut = _client != null
        ? _client.get(uri, headers: up.headers)
        : http.get(uri, headers: up.headers);
    return fut.timeout(const Duration(seconds: 20));
  }

  Future<HttpServer> _serve() async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    debugPrint('[DashProxy] listening on 127.0.0.1:${server.port}');
    server.listen((req) async {
      try {
        final doc = _docs[req.uri.path];
        if (doc != null) {
          await _serveText(req, doc);
          return;
        }
        final up = _upstream[req.uri.path];
        if (up == null) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        http.Response fetched;
        try {
          fetched = await _fetchUpstream(up);
        } catch (e) {
          debugPrint('[DashProxy] upstream fetch failed ${up.url}: $e');
          req.response.statusCode = HttpStatus.badGateway;
          await req.response.close();
          return;
        }
        if (fetched.statusCode != 200) {
          req.response.statusCode = HttpStatus.badGateway;
          await req.response.close();
          return;
        }
        if (up.isVariant) {
          // Sub-playlist HLS: absolutiza contra o CDN e troca os segmentos
          // por loopback (full-chain), cacheando o resultado.
          final tag = _tagOf(req.uri.path);
          var sub = rewriteHls(
              playlist: fetched.body,
              base: Uri.parse(up.url),
              height: null);
          sub = _swapToLoopback(sub, tag, up.headers, bareAreVariants: false);
          _docs[req.uri.path] = sub;
          await _serveText(req, sub);
          return;
        }
        // Segmento: repassa os bytes com o content-type do upstream.
        final bytes = fetched.bodyBytes;
        final ct = fetched.headers['content-type'];
        if (ct != null) {
          try {
            req.response.headers.contentType = ContentType.parse(ct);
          } catch (_) {}
        }
        req.response.contentLength = bytes.length;
        req.response.add(bytes);
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

  /// Tag numérica do manifesto de origem (`/af-<tag>...`) para agrupar
  /// variantes/segmentos da mesma sessão. -1 quando irreconhecível (as
  /// trocas seguem funcionando, só o agrupamento degrada).
  static int _tagOf(String path) {
    final m = RegExp(r'/af-(\d+)').firstMatch(path);
    return m == null ? -1 : int.tryParse(m.group(1)!) ?? -1;
  }

  Future<void> _serveText(HttpRequest req, String doc) async {
    // Bytes + Content-Length explícito: o demuxer DASH do ffmpeg relê o
    // manifesto e falha sobre chunked sem tamanho ("Unable to read
    // manifest" / "Failed to recognize file format"). Nunca use
    // String.length aqui (UTF-8 multi-byte, ex. "Português").
    // Content-type segue a extensão: o ExoPlayer decide DASH vs HLS
    // por ela (um `#EXTM3U` servido como `.mpd` morre no parser XML).
    final body = utf8.encode(doc);
    req.response.headers.contentType = req.uri.path.endsWith('.m3u8')
        ? ContentType.parse('application/x-mpegURL')
        : ContentType.parse('application/dash+xml');
    req.response.headers.set('Accept-Ranges', 'bytes');
    req.response.contentLength = body.length;
    req.response.add(body);
    await req.response.close();
  }

  Future<void> close() async {
    _docs.clear();
    _upstream.clear();
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

  /// True quando o corpo é playlist HLS (`#EXTM3U`) em vez de MPD — o
  /// AnimeFire varia o formato por episódio (`/m.jpg` = DASH, `/h.jpg` =
  /// HLS; visto ao vivo no Slime S4E21).
  @visibleForTesting
  static bool isHls({required String body}) =>
      body.trimLeft().startsWith('#EXTM3U');

  /// Pure rewrite de playlist HLS multivariant/mídia: absolutiza URIs de
  /// variantes e segmentos (relativas ao manifesto do CDN — via loopback
  /// resolveriam contra 127.0.0.1) e, com [height], mantém só a variante
  /// `RESOLUTION=Wx[height]`. Sem match → playlist cheia.
  @visibleForTesting
  static String rewriteHls({
    required String playlist,
    required Uri base,
    int? height,
  }) {
    final lines = playlist.split('\n');
    // Índices das linhas `#EXT-X-STREAM-INF` (cada uma + sua URI na próxima).
    final variantIdx = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) variantIdx.add(i);
    }
    Set<int> drop = const {};
    if (height != null && variantIdx.isNotEmpty) {
      final keep = <int>{};
      for (final i in variantIdx) {
        final h = int.tryParse(
            RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(lines[i])?.group(1) ??
                '');
        if (h == height) keep.add(i);
      }
      if (keep.isNotEmpty) {
        drop = variantIdx.toSet().difference(keep);
      }
    }
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (drop.contains(i)) {
        i++; // pula também a URI da variante descartada
        continue;
      }
      out.add(_absolutizeHlsLine(lines[i], base));
    }
    return out.join('\n');
  }

  static String _absolutizeHlsLine(String line, Uri base) {
    final t = line.trimRight();
    if (t.isEmpty || t.startsWith('#')) {
      // `URI="..."` (EXT-X-KEY/MAP) também pode ser relativo.
      return t.replaceAllMapped(
        RegExp('URI="([^"]+)"'),
        (m) => 'URI="${base.resolve(m.group(1)!)}"',
      );
    }
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    return base.resolve(t).toString();
  }

  /// Codecs de vídeo do manifesto (DASH `codecs="..."` em Representations
  /// `video...` + HLS `CODECS="..."` em variantes). No HLS o atributo
  /// mistura áudio e vídeo (`av01...,mp4a...`) — codecs de áudio conhecidos
  /// são descartados. Só o que o proxy precisa saber: se tudo é `av01`,
  /// um aparelho sem decoder AV1 toca som sobre tela preta — o player
  /// desvia para o fallback via software em vez disso.
  @visibleForTesting
  static Set<String> videoCodecs({required String body}) {
    final out = <String>{};
    final repRe = RegExp(r'<Representation\b[^>]*>', dotAll: true);
    for (final m in repRe.allMatches(body)) {
      final tag = m.group(0)!;
      if (!tag.contains('mimeType="video')) continue;
      final c = RegExp(r'codecs="([^"]+)"').firstMatch(tag)?.group(1);
      if (c != null && c.isNotEmpty) out.add(c);
    }
    for (final m in RegExp(r'CODECS="([^"]+)"').allMatches(body)) {
      for (final c in m.group(1)!.split(',')) {
        final codec = c.trim();
        if (codec.isEmpty || _isAudioCodec(codec)) continue;
        out.add(codec);
      }
    }
    return out;
  }

  static bool _isAudioCodec(String codec) {
    final c = codec.toLowerCase();
    return c.startsWith('mp4a') ||
        c.startsWith('ac-3') ||
        c.startsWith('ec-3') ||
        c.startsWith('opus') ||
        c.startsWith('vorbis');
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

/// Recurso do CDN a buscar sob demanda no handler loopback (full-chain
/// HLS): [url] + [headers] do app. [isVariant]: sub-playlist (parseia como
/// media playlist e troca os segmentos por loopback); senão, segmento
/// repassado byte a byte.
class _Upstream {
  final String url;
  final Map<String, String> headers;
  final bool isVariant;

  _Upstream(this.url, this.headers, {required this.isVariant});
}
