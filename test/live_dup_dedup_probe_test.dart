// Live probe for the search dedup (NOT CI): run:
//   flutter test test/live_dup_dedup_probe_test.dart --dart-define=LIVE=1
// Validates against relatorio-busca-duplicidade-fontes_MELHORADO.md §5:
//   one piece 51 -> 22-24 | black clover 24 -> 4-5 | naruto 59 -> 18-19 | solo leveling 30 -> 7
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/scraper/anime_scraper.dart';

void main() {
  final live = const String.fromEnvironment('LIVE') == '1';
  test('LIVE dedup probe', timeout: const Timeout(Duration(minutes: 10)), () async {
    if (!live) return;
    HttpOverrides.global = null;

    final report = StringBuffer();
    final queries = ['one piece', 'black clover', 'naruto', 'solo leveling'];
    for (final q in queries) {
      try {
        final start = DateTime.now();
        final results = await AnimeScraper.searchAnime(q);
        final ms = DateTime.now().difference(start).inMilliseconds;
        report.writeln('$q: ${results.length} cards after dedup (${ms}ms)');
        final bySource = <String, int>{};
        for (final a in results) {
          bySource[a.sourceName] = (bySource[a.sourceName] ?? 0) + 1;
        }
        report.writeln('  by source: ${bySource.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
        report.writeln('  titles: ${results.map((a) => '${a.name} [${a.anilistId}]').join(' | ')}');
      } catch (e) {
        report.writeln('$q: EXC $e');
      }
    }

    // ignore: avoid_print
    print(report.toString());
    File('/home/jabs/codes-ai/goanime-tv/.qa/dup_dedup_probe.txt')
        .writeAsStringSync(report.toString());
  });
}