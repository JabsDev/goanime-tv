import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _subtitleExtensions = {'.srt', '.sub', '.ass', '.ssa', '.vtt'};

/// Extrai o primeiro arquivo de legenda de um zip (bytes) retornado pelo
/// serviço. Retorna (extensão, bytes) ou null se não houver legenda.
({String extension, Uint8List bytes})? extractSubtitleFromZip(Uint8List zipBytes) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (_) {
    return null;
  }
  ArchiveFile? entry;
  for (final e in archive.files) {
    if (e.isFile) {
      final ext = _ext(e.name);
      if (_subtitleExtensions.contains(ext)) {
        entry = e;
        break;
      }
    }
  }
  if (entry == null) return null;
  final bytes = entry.content;
  if (bytes.length > 10 * 1024 * 1024) return null;
  return (extension: _ext(entry.name), bytes: bytes);
}

String _ext(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return '';
  return name.substring(i).toLowerCase();
}

/// Converte bytes para UTF-8 com BOM se necessário (mesma lógica do
/// LegendaLivre/Salvamento.ParaUtf8).
Uint8List ensureUtf8(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return bytes;
  }
  // Tenta UTF-8 estrito.
  if (utf8DecodeStrict(bytes) != null) {
    return bytes;
  }
  // Fallback: interpreta como latin1 (aproximação de Windows-1252) e reencoda.
  final text = latin1.decode(bytes);
  final out = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)];
  return Uint8List.fromList(out);
}

String? utf8DecodeStrict(Uint8List bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    return null;
  }
}
