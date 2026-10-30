import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/legendalivre/legendalivre_extract.dart';

void main() {
  test('extrai srt do zip', () {
    final archive = Archive();
    archive.addFile(ArchiveFile('movie.srt', 5, utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nhi')));
    final zip = ZipEncoder().encode(archive)!;
    final res = extractSubtitleFromZip(Uint8List.fromList(zip));
    expect(res, isNotNull);
    expect(res!.extension, '.srt');
    expect(utf8.decode(res.bytes), contains('hi'));
  });

  test('retorna null sem legenda', () {
    final archive = Archive();
    archive.addFile(ArchiveFile('readme.txt', 4, utf8.encode('text')));
    final zip = ZipEncoder().encode(archive)!;
    final res = extractSubtitleFromZip(Uint8List.fromList(zip));
    expect(res, isNull);
  });
}
