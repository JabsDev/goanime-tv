import 'dart:convert';
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
      return (nume: int.tryParse(m.group(4) ?? '') ?? 0, type: m.group(2)!, post: m.group(3)!);
    }).toList()
      ..sort((a, b) => a.nume.compareTo(b.nume));

    final byNume = <int, ({String type, String post})>{};
    final seenNumes = <int>{};
    for (final o in options) {
      if (seenNumes.add(o.nume)) byNume[o.nume] = (type: o.type, post: o.post);
    }

    final scored = <(String, int)>[]; // (url, content-length)
    for (final entry in byNume.entries) {
      final payload = await _fetchPayload(method, apiHost, entry.value, entry.key, episodeUrl);
      final embed = payload?['embed_url']?.toString();
      if (embed == null || embed.isEmpty) continue;
      if (payload?['type']?.toString() != 'mp4' && !(embed.toLowerCase().contains('.mp4'))) {
        continue; // iframe/blogger/SPA — try next option
      }
      final src = mp4FromEmbed(embed);
      if (src == null) continue;
      final size = await probeMediaUrl(Uri.parse(src),
          headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'});
      if (size >= 0) scored.add((src, size));
    }

    // Camada C: bigger file first as the primary source (cheap quality proxy).
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final sources = <VideoSource>[];
    for (final s in scored) {
      sources.add(VideoSource(
        url: s.$1,
        quality: sources.isEmpty ? 'Auto' : 'Alternativa',
        headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'},
      ));
    }
    if (sources.isEmpty) {
      throw NoPlayableOption('no type=mp4 option answered 206');
    }
    return sources;
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