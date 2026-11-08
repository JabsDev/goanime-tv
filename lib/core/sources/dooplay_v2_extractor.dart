import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/episode.dart';
import 'cdn_resolver.dart' show probeMediaUrl;

/// Thrown when no player option yields a 206-checked direct stream.
final class NoPlayableOption implements Exception {
  final String message;
  const NoPlayableOption(this.message);
  @override
  String toString() => 'NoPlayableOption: $message';
}

/// Shared extractor for the AnimesOnline-cluster WordPress theme (DooPlay):
/// reads every `li.dooplay_player_option` on an episode page, resolves each
/// option through the theme's player API, keeps the `type=mp4` candidates and
/// offers only URLs that answer a 206 range probe.
///
/// Transport is theme-dependent (`dtAjax.play_method`):
///  - `wp_json`    → GET  <player_api><post>/<type>/<nume>
///  - `admin_ajax` → POST <url> action=doo_player_ajax&post=…&nume=…&type=…
/// Both return the same JSON (`embed_url` + `type`).
///
/// The `source=` query param is decoded exactly ONCE (`Uri.queryParameters`
/// already percent-decodes; a second decode would turn `%20` into a literal
/// space and the CDN would answer 000).
class DooPlayV2Extractor {
  DooPlayV2Extractor({
    required this.baseUrl,
    http.Client? client,
  }) : _client = client;

  final String baseUrl;
  final http.Client? _client;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) return _client.get(uri, headers: headers);
    return http.get(uri, headers: headers).timeout(const Duration(seconds: 20));
  }

  Future<http.Response> _post(Uri uri, {Map<String, String>? headers, String? body}) async {
    if (_client != null) return _client.post(uri, headers: headers, body: body);
    return http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 20));
  }

  static final RegExp _optionRe = RegExp(
    r"id='player-option-(\d+)'[^>]*class='[^']*dooplay_player_option[^']*'[^>]*data-type='([^']+)'[^>]*data-post='(\d+)'[^>]*data-nume='([\d.]+)'",
  );

  static final RegExp _ajaxBlobRe = RegExp(
    r'dtAjax\s*=\s*(\{.*?\})\s*;?',
    dotAll: true,
  );
  static final RegExp _ajaxApiRe = RegExp(r'"player_api"\s*:\s*"([^"]*)"');
  static final RegExp _ajaxMethodRe = RegExp(r'"play_method"\s*:\s*"([^"]*)"');

  /// Extracts the direct mp4/m3u8 URL from a dooplayer `embed_url` (the
  /// `source` query param, decoded once), or null when the option is not a
  /// direct stream (iframe/blogger/b64 token).
  static String? mp4FromEmbed(String embedUrl) {
    final u = Uri.tryParse(embedUrl);
    if (u == null) return null;
    final lowered = embedUrl.toLowerCase();
    if (lowered.contains('.mp4') || lowered.contains('.m3u8')) {
      if (lowered.startsWith('http')) {
        final src = u.queryParameters['source'];
        if (src != null && src.isNotEmpty) return src;
        return embedUrl;
      }
    }
    final src = u.queryParameters['source'];
    if (src == null || src.isEmpty) return null;
    if (!(src.toLowerCase().contains('.mp4') ||
        src.toLowerCase().contains('.m3u8'))) {
      return null; // non-URL source (base64 token) → legacy resolver
    }
    return src;
  }

  /// Resolves every playable stream for [episodeUrl]. Impossible when every
  /// option is iframe/SPA or all candidates fail the range probe.
  Future<List<VideoSource>> extractPlayable(String episodeUrl) async {
    final page = await _get(Uri.parse(episodeUrl),
        headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'});
    if (page.statusCode != 200) {
      throw NoPlayableOption('episode page HTTP ${page.statusCode}');
    }
    final body = page.body;
    final method = _playMethod(body);
    final apiHost = _playerApi(body);

    final options = _optionRe.allMatches(body).map((m) {
      // O rótulo real (SD/HD/FHD) vive no `<span class='title'>` do mesmo
      // `<li>`; sem ele o picker mostrava "Auto/Alternativa".
      final end = body.indexOf('</li>', m.start);
      final block = body.substring(m.start, end < 0 ? body.length : end);
      final label = RegExp(r"<span class='title'>([^<]*)</span>")
              .firstMatch(block)
              ?.group(1)
              ?.trim() ??
          '';
      return (
        nume: int.tryParse(m.group(4) ?? '') ?? 0,
        type: m.group(2)!,
        post: m.group(3)!,
        label: label,
      );
    }).toList()
      ..sort((a, b) => a.nume.compareTo(b.nume));

    final byNume = <int, ({String type, String post, String label})>{};
    final seenNumes = <int>{};
    for (final o in options) {
      if (seenNumes.add(o.nume)) {
        byNume[o.nume] = (type: o.type, post: o.post, label: o.label);
      }
    }

    // Player novo (`animeq-player`, visto em animesdrive/animeq desde out/2026):
    // os streams já vêm no HTML, sem `dooplay_player_option`. Sem isto a
    // extração antiga não acha nenhuma opção e a fonte "existe" mas não toca.
    final inline = _inlineSources(body);
    final scored = <({String url, int size, String? label})>[];
    for (final s in inline) {
      final size = await probeMediaUrl(Uri.parse(s.url),
          headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'});
      if (size >= 0) scored.add((url: s.url, size: size, label: s.label));
    }

    for (final entry in byNume.entries) {
      final payload = await _fetchPayload(
        method,
        apiHost,
        (type: entry.value.type, post: entry.value.post),
        entry.key,
        episodeUrl,
      );
      final embed = payload?['embed_url']?.toString();
      if (embed == null || embed.isEmpty) continue;
      if (payload?['type']?.toString() != 'mp4' && !(embed.toLowerCase().contains('.mp4'))) {
        continue; // iframe/blogger/SPA — try next option
      }
      final src = mp4FromEmbed(embed);
      if (src == null) continue;
      final size = await probeMediaUrl(Uri.parse(src),
          headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'});
      if (size >= 0) {
        scored.add((
          url: src,
          size: size,
          label: entry.value.label.isEmpty ? null : entry.value.label,
        ));
      }
    }

    // Dedupe por URL (inline ganha o rótulo real SD/HD/FHD) e depois camada C:
    // arquivo maior primeiro como proxy barato de qualidade.
    final seenUrls = <String>{};
    final unique = scored.where((s) => seenUrls.add(s.url)).toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    final sources = <VideoSource>[];
    for (final s in unique) {
      sources.add(VideoSource(
        url: s.url,
        quality: s.label ?? (sources.isEmpty ? 'Auto' : 'Alternativa'),
        headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'},
      ));
    }
    if (sources.isEmpty) {
      throw NoPlayableOption('no playable stream answered 206');
    }
    return sources;
  }

  /// Streams do player inline `animeq-player`: cada
  /// `div[data-animeq-source="N"]` pode ter `<video><source src=…>` (direto) ou
  /// um iframe (Blogger — ignorado). O rótulo vem do botão
  /// `[data-animeq-switch="N"]` (`data-source-name="SD|HD|FHD"`), casado pelo
  /// índice do bloco (não pela ordem dos `<video>`, que pula os iframes).
  static List<({String url, String label})> _inlineSources(String body) {
    final doc = html_parser.parse(body);
    final names = <String, String>{};
    for (final b in doc.querySelectorAll('[data-animeq-switch]')) {
      final idx = b.attributes['data-animeq-switch']?.trim();
      final name = (b.attributes['data-source-name'] ?? b.text).trim();
      if (idx != null && idx.isNotEmpty && name.isNotEmpty) names[idx] = name;
    }
    final out = <({String url, String label})>[];
    for (final block in doc.querySelectorAll('[data-animeq-source]')) {
      final idx = block.attributes['data-animeq-source']?.trim();
      for (final s in block.querySelectorAll('video source[src]')) {
        final src = s.attributes['src']?.trim() ?? '';
        if (!src.startsWith('http')) continue;
        out.add((url: src, label: names[idx] ?? 'Auto'));
      }
    }
    if (out.isEmpty) {
      // Variante sem o wrapper por servidor: aceita qualquer <video><source>.
      for (final s in doc.querySelectorAll('video source[src]')) {
        final src = s.attributes['src']?.trim() ?? '';
        if (!src.startsWith('http')) continue;
        out.add((url: src, label: 'Auto'));
      }
    }
    return out;
  }

  String? _playMethod(String body) {
    final blob = _ajaxBlobRe.firstMatch(body)?.group(1);
    if (blob == null) return 'wp_json';
    return _ajaxMethodRe.firstMatch(blob)?.group(1) ?? 'wp_json';
  }

  /// Absolute player API base ("…/wp-json/dooplayer/v2/"); falls back to the
  /// classic endpoint when `dtAjax` is missing.
  String _playerApi(String body) {
    final blob = _ajaxBlobRe.firstMatch(body)?.group(1);
    if (blob != null) {
      final api = _ajaxApiRe.firstMatch(blob)?.group(1);
      if (api != null && api.isNotEmpty) return api;
    }
    return '$baseUrl/wp-json/dooplayer/v2/';
  }

  Future<Map<String, dynamic>?> _fetchPayload(
    String? method,
    String playerApi,
    ({String type, String post}) opt,
    int nume,
    String episodeUrl,
  ) async {
    try {
      if (method == 'admin_ajax') {
        final body = 'action=doo_player_ajax&post=${opt.post}&nume=$nume&type=${opt.type}';
        final res = await _post(
          Uri.parse('$baseUrl/wp-admin/admin-ajax.php'),
          headers: {
            'User-Agent': _ua,
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': episodeUrl,
          },
          body: body,
        );
        return _decode(res.body);
      }
      final apiBase = playerApi.startsWith('http') ? playerApi : '$baseUrl$playerApi';
      final url = Uri.parse('$apiBase${opt.post}/${opt.type}/$nume');
      final res = await _get(url, headers: {'User-Agent': _ua, 'Referer': episodeUrl});
      return _decode(res.body);
    } catch (e) {
      return null;
    }
  }

  Map<String, dynamic>? _decode(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }
}