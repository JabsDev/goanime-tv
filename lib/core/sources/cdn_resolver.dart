import 'package:http/http.dart' as http;

/// Range probe for a direct media URL. Sends `Range: bytes=0-0`; a 206 means
/// the file is seekable and the player can stream it. Returns the full size
/// from the `Content-Range` header (used as a cheap quality proxy) or null
/// when the URL is not directly playable.
Future<int> probeMediaUrl(
  Uri uri, {
  http.Client? client,
  Map<String, String>? headers,
}) async {
  try {
    final res = client != null
        ? await client.get(uri, headers: {"Range": "bytes=0-0", ...?headers})
        : await http.get(uri, headers: {"Range": "bytes=0-0", ...?headers})
            .timeout(const Duration(seconds: 15));
    if (res.statusCode != 206) return -1;
    final cr = res.headers['content-range'];
    final m = RegExp(r'/(\d+)$').firstMatch(cr ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  } catch (e) {
    return -1;
  }
}

/// Layer B (best-effort): reconstructs the direct CDN mp4 for `title + episode`
/// when the aggregator API (Layer A) fails. CDN folders are inconsistent
/// ("OnePiece" vs "One Piece Dublado" vs "Solo Leveling/Dub"), so a matrix of
/// title/file variants is probed serially; only a 206 is ever offered.
///
/// ponytail: cache keyed by "title|episode", probed order fixed — fine while
/// per-episode misses are rare; a title-level success cache would spare the
/// repeated variant scans when episode counts grow.
class CdnResolver {
  CdnResolver({http.Client? client, List<String>? hosts})
      : _client = client,
        hosts = hosts ?? _defaultHosts;

  final http.Client? _client;
  final List<String> hosts;

  static const _defaultHosts = ['https://mangas.cloud', 'https://animeflix.blog'];

  static DateTime _lastProbe = DateTime.fromMillisecondsSinceEpoch(0);
  static const _probeGap = Duration(milliseconds: 150);

  final Map<String, String> _cache = {};

  /// Attempts to find a playable CDN URL for [episode] of [title]. Returns null
  /// when no variant answers 206.
  Future<String?> resolve(String title, int episode,
      {String? englishName}) async {
    final key = '$title|$episode';
    final cached = _cache[key];
    if (cached != null) return cached.isEmpty ? null : cached;

    String? found;
    final urls = buildCandidateUrls(title, episode.toString(),
        englishName: englishName);
    // ponytail: varredura em raias — o scan serial estourava o step de 8s do
    // provider quando o acerto estava fundo na matriz (One Piece Dublado
    // = URL #49). Primeira 206 vence e o resto nem é buscado.
    const lanes = 8;
    for (var i = 0; i < urls.length && found == null; i += lanes) {
      final batch = urls.skip(i).take(lanes);
      await _throttle();
      final results = await Future.wait(batch.map((url) async {
        try {
          final ok = await probeMediaUrl(Uri.parse(url), client: _client)
              .timeout(const Duration(seconds: 4));
          return ok > 0 ? url : null;
        } catch (_) {
          return null;
        }
      }));
      for (final url in results) {
        if (url != null) {
          found = url;
          break;
        }
      }
    }
    _cache[key] = found ?? '';
    return found;
  }

  Future<void> _throttle() async {
    final now = DateTime.now();
    final since = now.difference(_lastProbe).inMilliseconds;
    if (since < _probeGap.inMilliseconds) {
      await Future.delayed(
          Duration(milliseconds: _probeGap.inMilliseconds - since));
    }
    _lastProbe = DateTime.now();
  }

  static final RegExp _stripDublado = RegExp(r'[^a-z0-9]?dublado$', caseSensitive: false);

  /// Title variants likely to match a CDN folder: display title, without the
  /// "Dublado" suffix (the folder may rely on the /Dub/ subpath instead),
  /// WITH the "Dublado" suffix (folders like "One Piece Dublado" carry it in
  /// the name — verified live: 130/131/132 206 there, 404 without it),
  /// spaces removed ("OnePiece"), and the english name.
  static List<String> titleVariants(String title, {String? englishName}) {
    // Alt-text dos sites vem sujo ("One Piece –", "Naruto -"): limpa
    // pontuação solta no fim antes de derivar, senão TODAS as variantes
    // carregam o lixo e a pasta certa nunca é tentada (visto ao vivo no
    // animesdrive). Parênteses/anos no fim são preservados.
    String scrub(String s) => s
        .replaceAll(RegExp(r'[\s\-–—:;|]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final base = scrub(title);
    final set = <String>{if (base.isNotEmpty) base};
    final noDub = base.replaceAll(_stripDublado, '').trim();
    if (noDub.isNotEmpty && noDub != base) set.add(noDub);
    set.add(base.replaceAll(RegExp(r'\s+'), ''));
    set.add(base.replaceAll(RegExp(r'\s+'), '').replaceAll(_stripDublado, ''));
    // Sufixo dublado (só quando ainda não há): cobre pastas "X Dublado".
    void withDub(String b) {
      final t = b.trim();
      if (t.isEmpty || _stripDublado.hasMatch(t)) return;
      set.add('$t Dublado');
      set.add('$t Dublado'.replaceAll(RegExp(r'\s+'), ''));
    }

    withDub(base);
    if (englishName != null && englishName.isNotEmpty) {
      final en = scrub(englishName);
      if (en.isNotEmpty) {
        set.add(en);
        set.add(en.replaceAll(RegExp(r'\s+'), ''));
        withDub(en);
      }
    }
    set.removeWhere((v) => v.isEmpty);
    return set.toList();
  }

  /// Builds the ordered candidate URLs for a title/episode in probe order:
  /// rarest/plain variant first, padding-3 next (some folders only serve
  /// `01.mp4`, not `010.mp4`), then the `/Dub/` subfolder and the `-sd` suffix.
  static List<String> buildCandidateUrls(String title, String episode,
      {String? englishName, List<String>? hosts}) {
    final hs = hosts ?? _defaultHosts;
    final ep = int.tryParse(episode)?.toString() ?? episode;
    final pad2 = ep.padLeft(2, '0');
    final pad3 = ep.padLeft(3, '0');
    final out = <String>[];
    for (final host in hs) {
      var prev = '';
      for (final variant in titleVariants(title, englishName: englishName)) {
        if (variant == prev) continue;
        prev = variant;
        final trimmed = variant.trim();
        if (trimmed.isEmpty) continue;
        final first = trimmed[0].toUpperCase();
        if (!RegExp(r'[A-Z]').hasMatch(first)) continue;
        final base = '$host/Animes/Letra-$first/$variant';
        for (final file in [ep, pad2, pad3]) {
          out.add('$base/$file.mp4');
          out.add('$base/$file-sd.mp4');
          out.add('$base/Dub/$file.mp4');
          out.add('$base/Dub/$file-sd.mp4');
        }
      }
    }
    return out.toList();
  }
}