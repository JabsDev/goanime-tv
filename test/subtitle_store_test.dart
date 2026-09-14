import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/srt_parser.dart';
import 'package:goanime_tv/core/subtitles/subtitle_store.dart';

const _enSrt = '''
1
00:00:01,000 --> 00:00:03,500
Hello, world!

2
00:00:04,000 --> 00:00:06,000
Second line
over two lines
''';

void main() {
  group('SrtParser', () {
    test('parse preserva tempos e texto', () {
      final cues = SrtParser.parse(_enSrt);
      expect(cues, hasLength(2));
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 3, milliseconds: 500));
      expect(cues[0].text, 'Hello, world!');
      expect(cues[1].text, 'Second line\nover two lines');
    });

    test('round-trip format->parse', () {
      final cues = SrtParser.parse(_enSrt);
      expect(SrtParser.parse(SrtParser.format(cues)), hasLength(2));
    });

    test('detectLang: tag > filename', () {
      expect(SrtParser.detectLang(tag: 'English'), 'en');
      expect(SrtParser.detectLang(filename: 'ep1.es.srt'), 'es');
      expect(SrtParser.detectLang(filename: 'ep1.ja.srt'), 'ja');
      expect(SrtParser.detectLang(filename: 'ep1.srt'), isNull);
    });
  });

  group('SubtitleStore TTL 5d', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('subs_test');
      SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14));
    });

    tearDown(() async {
      SubtitleStore.setClockForTest(null);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('get válido dentro do TTL', () async {
      await SubtitleStore.put(
          animeKey: 'haibane', ep: 1, tag: 'en-marian',
          srt: _enSrt, srcHash: 'abc', subsDirForTest: tmp);
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 1, tag: 'en-marian', subsDirForTest: tmp);
      expect(f, isNotNull);
    });

    test('get expirado retorna null E deleta arquivos', () async {
      await SubtitleStore.put(
          animeKey: 'haibane', ep: 1, tag: 'en-marian',
          srt: _enSrt, srcHash: 'abc', subsDirForTest: tmp);
      SubtitleStore.setClockForTest(() => DateTime(2026, 9, 14)
          .add(SubtitleStore.kSrtTtl)
          .add(const Duration(seconds: 1)));
      final f = await SubtitleStore.get(
          animeKey: 'haibane', ep: 1, tag: 'en-marian', subsDirForTest: tmp);
      expect(f, isNull);
      final left = await tmp
          .list(recursive: true)
          .where((e) => e is File)
          .toList();
      expect(left, isEmpty);
    });

    test('acesso NÃO renova (TTL fixo desde createdAt)', () async {
      await SubtitleStore.put(
          animeKey: 'haibane', ep: 1, tag: 'en-marian',
          srt: _enSrt, srcHash: 'abc', subsDirForTest: tmp);
      SubtitleStore.setClockForTest(
          () => DateTime(2026, 9, 14).add(const Duration(days: 4)));
      expect(await SubtitleStore.get(
          animeKey: 'haibane', ep: 1, tag: 'en-marian',
          subsDirForTest: tmp), isNotNull);
      SubtitleStore.setClockForTest(
          () => DateTime(2026, 9, 14).add(const Duration(days: 5, seconds: 1)));
      expect(await SubtitleStore.get(
          animeKey: 'haibane', ep: 1, tag: 'en-marian',
          subsDirForTest: tmp), isNull);
    });

    test('prune remove só expirados', () async {
      await SubtitleStore.put(
          animeKey: 'haibane', ep: 1, tag: 'en-marian',
          srt: _enSrt, srcHash: 'a', subsDirForTest: tmp);
      SubtitleStore.setClockForTest(
          () => DateTime(2026, 9, 14).add(const Duration(days: 4)));
      await SubtitleStore.put(
          animeKey: 'haibane', ep: 2, tag: 'en-marian',
          srt: _enSrt, srcHash: 'b', subsDirForTest: tmp);
      SubtitleStore.setClockForTest(
          () => DateTime(2026, 9, 14).add(const Duration(days: 5, seconds: 1)));
      final removed = await SubtitleStore.pruneExpired(subsDirForTest: tmp);
      expect(removed, 1);
      expect(await SubtitleStore.get(
          animeKey: 'haibane', ep: 2, tag: 'en-marian',
          subsDirForTest: tmp), isNotNull);
      expect(await SubtitleStore.get(
          animeKey: 'haibane', ep: 1, tag: 'en-marian',
          subsDirForTest: tmp), isNull);
    });
  });
}
