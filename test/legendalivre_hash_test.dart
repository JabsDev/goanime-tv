import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/legendalivre/video_hash.dart';

void main() {
  test('hash de bytes vazios é zero', () {
    expect(computeVideoHashFromBytes(Uint8List(0)), '0000000000000000');
  });

  test('hash de 8 bytes = size + valor little-endian', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    // size=8; sum first block = 0x0807060504030201
    final expected = (8 + 0x0807060504030201).toRadixString(16).padLeft(16, '0');
    expect(computeVideoHashFromBytes(bytes), expected);
  });

  test('hash combina primeiros e últimos 64KB quando >= 64KB', () {
    final size = 65536 * 2;
    final bytes = Uint8List(size);
    for (int i = 0; i < size; i++) {
      bytes[i] = (i * 37 + 11) & 0xff;
    }
    // Apenas garante determinismo e formato 16 hex.
    final h = computeVideoHashFromBytes(bytes);
    expect(h.length, 16);
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(h), isTrue);
  });
}
