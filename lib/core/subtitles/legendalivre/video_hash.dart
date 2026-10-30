import 'dart:typed_data';

import 'package:http/http.dart' as http;

const _block = 65536;
const _mask = (1 << 64) - 1;

/// Calcula o hash OpenSubtitles/LegendaLivre (64 bits) a partir dos bytes
/// de um arquivo de vídeo já em memória. Mesmo algoritmo de
/// LegendaLivre/ImpressaoDigital.cs.
String computeVideoHashFromBytes(Uint8List bytes) {
  final size = bytes.length;
  int soma = size & _mask;

  int sumBlock(int start, int n) {
    int s = 0;
    for (int i = 0; i + 8 <= n; i += 8) {
      int v = 0;
      for (int j = 7; j >= 0; j--) {
        v = (v << 8) | bytes[start + i + j];
      }
      s = (s + v) & _mask;
    }
    return s;
  }

  final n = size < _block ? size : _block;
  soma = (soma + sumBlock(0, n)) & _mask;
  if (size >= _block) {
    soma = (soma + sumBlock(size - _block, _block)) & _mask;
  }
  return soma.toRadixString(16).padLeft(16, '0');
}

/// Calcula o hash a partir de uma URL de vídeo, buscando apenas os primeiros
/// e últimos 64 KB via Range requests (não baixa o arquivo inteiro).
Future<String> computeRemoteVideoHash(
  Uri uri, {
  Map<String, String> headers = const {},
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  final owns = client == null;
  try {
    int? size = await _contentLength(c, uri, headers);
    if (size == null) {
      throw StateError('Não foi possível obter o tamanho do vídeo');
    }

    final firstN = size < _block ? size : _block;
    final first = await _fetchRange(c, uri, headers, 0, firstN - 1);
    Uint8List last = Uint8List(0);
    if (size >= _block) {
      last = await _fetchRange(c, uri, headers, size - _block, size - 1);
    }

    // Reaproveita o algoritmo juntando first+last em um buffer virtual.
    // Para simplificar, replica a soma aqui.
    int soma = size & _mask;
    int sumBuf(Uint8List buf, int n) {
      int s = 0;
      for (int i = 0; i + 8 <= n; i += 8) {
        int v = 0;
        for (int j = 7; j >= 0; j--) {
          v = (v << 8) | buf[i + j];
        }
        s = (s + v) & _mask;
      }
      return s;
    }

    soma = (soma + sumBuf(first, first.length)) & _mask;
    if (size >= _block && last.isNotEmpty) {
      soma = (soma + sumBuf(last, last.length)) & _mask;
    }
    return soma.toRadixString(16).padLeft(16, '0');
  } finally {
    if (owns) c.close();
  }
}

Future<int?> _contentLength(
    http.Client c, Uri uri, Map<String, String> headers) async {
  // HEAD
  try {
    final res = await c.head(uri, headers: headers);
    final cl = res.headers['content-length'];
    if (cl != null) {
      final v = int.tryParse(cl);
      if (v != null && v >= 0) return v;
    }
  } catch (_) {}
  // Fallback: Range 0-0
  try {
    final req = http.Request('GET', uri);
    req.headers.addAll(headers);
    req.headers['Range'] = 'bytes=0-0';
    final res = await c.send(req);
    final cr = res.headers['content-range'];
    await res.stream.drain<void>();
    if (cr != null) {
      final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
      if (m != null) {
        final v = int.tryParse(m.group(1)!);
        if (v != null) return v;
      }
    }
    final cl = res.headers['content-length'];
    if (cl != null && res.statusCode == 200) {
      final v = int.tryParse(cl);
      if (v != null) return v;
    }
  } catch (_) {}
  return null;
}

Future<Uint8List> _fetchRange(
  http.Client c,
  Uri uri,
  Map<String, String> headers,
  int start,
  int end,
) async {
  final req = http.Request('GET', uri);
  req.headers.addAll(headers);
  req.headers['Range'] = 'bytes=$start-$end';
  final res = await c.send(req);
  if (res.statusCode != 206 && res.statusCode != 200) {
    throw StateError('HTTP ${res.statusCode} ao buscar range');
  }
  final target = end - start + 1;
  final builder = BytesBuilder(copy: false);
  await for (final chunk in res.stream) {
    builder.add(chunk);
    if (builder.length >= target) break;
  }
  final bytes = builder.takeBytes();
  if (bytes.length > target) {
    return Uint8List.fromList(bytes.sublist(0, target));
  }
  return bytes;
}
