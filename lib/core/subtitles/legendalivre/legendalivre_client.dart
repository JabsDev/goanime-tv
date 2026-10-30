import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// Cliente do serviço público de legendas usado pelo LegendaLivre
/// (getsubtitle.com). Não exige chave de acesso do usuário — o protocolo é
/// o mesmo do app original (versão 383), com os parâmetros enviados no corpo
/// POST como form-urlencoded.
class LegendaLivreLegend {
  final String name;
  final String id;
  final String date;

  const LegendaLivreLegend({
    required this.name,
    required this.id,
    required this.date,
  });
}

class LegendaLivreClient {
  static const base = 'https://www.getsubtitle.com/webService/downloadManager/';
  static const protocolVersion = 383;

  // Códigos de idioma do serviço (LegendaLivre/Idioma.cs).
  static const int langPtBr = 6;
  static const int langPtPt = 36;
  static const int langEn = 14;

  final http.Client _client;
  final bool _ownsClient;

  LegendaLivreClient({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Codificação idêntica à do LegendaLivre: base64 → URL-encode.
  static String _encode(String text) =>
      Uri.encodeComponent(base64.encode(utf8.encode(text)));

  Future<List<LegendaLivreLegend>> listSubtitles({
    required String hash,
    required int langCode,
    bool best = false,
  }) async {
    final endpoint =
        best ? 'get_best_subtitle_by_hash.php' : 'get_subtitles_by_hash.php';
    final body =
        'version=$protocolVersion&response=xml&cod_language=$langCode&hash=${_encode(hash)}';
    final res = await _post(endpoint, body);
    return _parseList(res.body, best: best);
  }

  Future<String?> movieName(String hash) async {
    final body =
        'version=$protocolVersion&response=xml&hash=${_encode(hash)}';
    final res = await _post('get_movie_by_hash.php', body);
    final text = res.body;
    if (text.trim().isEmpty) return null;
    try {
      final doc = XmlDocument.parse(text);
      final root = doc.rootElement;
      final id = _decodeField(root, 'id');
      final name = _decodeField(root, 'name');
      final idOk = RegExp(r'^[0-9]+$').hasMatch(id ?? '');
      if (!idOk || name == null || name.trim().isEmpty || name.length > 300) {
        return null;
      }
      return name.trim();
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> downloadZip(LegendaLivreLegend legend) async {
    final body =
        'version=$protocolVersion&response=single&cod_bsplayer=${_encode(legend.id)}&post_date=${_encode(legend.date)}';
    final res = await _post('get_subtitle_files.php', body);
    final bytes = res.bodyBytes;
    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4B) {
      throw StateError(
          'Download da legenda ${legend.id} não devolveu zip '
          '(${res.headers['content-type']}, ${bytes.length} bytes)');
    }
    return bytes;
  }

  Future<http.Response> _post(String endpoint, String body) async {
    final uri = Uri.parse('$base$endpoint');
    final req = http.Request('POST', uri);
    req.headers['User-Agent'] = 'LegendaLivre/$protocolVersion';
    req.headers['Content-Type'] = 'application/x-www-form-urlencoded';
    req.headers['Accept-Encoding'] = 'gzip, deflate';
    req.body = body;
    final streamed = await _client.send(req).timeout(const Duration(seconds: 20));
    final res = await http.Response.fromStream(streamed)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode} em $endpoint');
    }
    return res;
  }

  static List<LegendaLivreLegend> _parseList(String text, {bool best = false}) {
    final out = <LegendaLivreLegend>[];
    if (text.trim().isEmpty) return out;
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } catch (_) {
      return out;
    }
    final nodes = best
        ? doc.findAllElements('subtitle')
        : doc.findAllElements('subtitle');
    for (final n in nodes) {
      try {
        final name = _decodeFieldNode(n, 'name') ?? '';
        final id = _decodeFieldNode(n, 'id') ?? '';
        final date = _decodeFieldNode(n, 'date') ?? '';
        if (!RegExp(r'^[0-9]+$').hasMatch(id)) continue;
        if (!best && name.trim().isEmpty) continue;
        // valida data dd-MM-yyyy
        if (!_validDate(date)) continue;
        out.add(LegendaLivreLegend(name: name, id: id, date: date));
      } catch (_) {
        // ignora registro inválido
      }
    }
    return out;
  }

  static String? _decodeField(XmlElement root, String field) {
    final node = root.findElements(field).firstOrNull;
    if (node == null) return null;
    final inner = node.innerText.trim();
    if (inner.isEmpty) return null;
    try {
      return utf8.decode(base64.decode(inner));
    } catch (_) {
      return null;
    }
  }

  static String? _decodeFieldNode(XmlElement node, String field) {
    final el = node.findElements(field).firstOrNull;
    if (el == null) return null;
    final inner = el.innerText.trim();
    if (inner.isEmpty) return null;
    try {
      return utf8.decode(base64.decode(inner));
    } catch (_) {
      return null;
    }
  }

  static bool _validDate(String s) {
    // dd-MM-yyyy
    final m = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch(s);
    if (m == null) return false;
    final d = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final y = int.tryParse(m.group(3)!);
    if (d == null || mo == null || y == null) return false;
    if (mo < 1 || mo > 12) return false;
    if (d < 1 || d > 31) return false;
    return true;
  }
}
