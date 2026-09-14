import 'dart:convert';
import 'dart:io';

import '../../data/models/episode.dart';

/// Sonda de legendas em manifestos HLS: `EXT-X-MEDIA:TYPE=SUBTITLES`
/// (grupo com URI de `.vtt`/`.m3u8` + LANGUAGE/NAME).
/// É a fonte real da Rota S — sem isto, `subtitleCandidates` vive vazio e
/// o picker só oferece transcrição de JA cru. Falha aberta: sem grupo,
/// timeout ou erro → lista vazia (nunca quebra a resolução).
/// `fetchForTest` injeta o corpo do manifesto p/ teste sem rede.
class HlsSubtitleProbe {
  const HlsSubtitleProbe._();

  static final _media = RegExp(r'#EXT-X-MEDIA:([^\n]+)');
  static final _attr = RegExp(r'([A-Z-]+)=("[^"]*"|[^,]*)');

  static Future<List<SubtitleRef>> probe(
    String masterUrl, {
    Map<String, String> headers = const {},
    Future<String> Function(Uri url)? fetchForTest,
  }) async {
    if (!masterUrl.toLowerCase().contains('.m3u8')) return const [];
    try {
      final uri = Uri.parse(masterUrl);
      final body = fetchForTest != null
          ? await fetchForTest(uri)
          : await _get(uri, headers);
      return parse(body, baseUri: uri);
    } catch (_) {
      return const [];
    }
  }

  /// Parse puro (testável): extrai só grupos SUBTITLES com URI.
  static List<SubtitleRef> parse(String manifest, {required Uri baseUri}) {
    final out = <SubtitleRef>[];
    for (final m in _media.allMatches(manifest)) {
      final attrs = <String, String>{};
      for (final a in _attr.allMatches(m.group(1)!)) {
        attrs[a.group(1)!] =
            a.group(2)!.replaceAll(RegExp(r'^"|"$'), '');
      }
      if (attrs['TYPE'] != 'SUBTITLES') continue; // CEA-608 embutido: fora
      final groupUri = attrs['URI'];
      if (groupUri == null || groupUri.isEmpty) continue;
      final lang = (attrs['LANGUAGE'] ?? '').toLowerCase();
      final name = attrs['NAME'] ?? lang;
      out.add(SubtitleRef(
        label: name.isEmpty ? 'Legenda' : name,
        lang: lang.isEmpty ? 'und' : lang,
        uri: baseUri.resolve(groupUri).toString(),
      ));
    }
    return out;
  }

  static Future<String> _get(Uri uri, Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      headers.forEach(req.headers.set);
      final resp =
          await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return '';
      return await resp.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 10));
    } finally {
      client.close();
    }
  }
}
