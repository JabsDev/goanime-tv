// Live probe #2 — runs the REAL app path (AnimeScraper + AnimeRepository) for
// the 4 QA animes, then resolves a few episode numbers across all providers.
// Run:  flutter test test/live_path_probe_test.dart --dart-define=LIVE=1 --timeout 20m
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';
import 'package:goanime_tv/core/scraper/anime_scraper.dart';

const _queries = ['One Piece', 'Black Clover', 'Black Butler', 'Haibane Renmei'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final live = const String.fromEnvironment('LIVE') == '1';
  test(
    'LIVE real-path probe',
    () async {
      if (!live) return;
      HttpOverrides.global = null;
      final repo = AnimeRepository();
      final report = StringBuffer();

      for (final q in _queries) {
        report.writeln('\n===== $q =====');
        final results = await AnimeScraper.searchAnime(q);
        report.writeln('SEARCH total=${results.length}');
        for (final a in results) {
          report.writeln(
            '  src=${a.source.name} name="${a.name}" eps=${a.episodes} url=${a.url.length > 70 ? a.url.substring(0, 70) : a.url}');
        }
        if (results.isEmpty) continue;

        // The app opens the first (top-priority) result → canonical grid.
        final anime = results.first;
        final catalog = await repo.getCatalogEpisodes(anime);
        report.writeln(
            'CATALOG opened="${anime.name}" anilistId=${anime.anilistId} total=${catalog.length}');

        final picks = [1, 5, 10, 15, 20];
        for (final n in picks) {
          // Real flow: repo resolves the episode across every provider.
          final res = await repo.resolveProvidersForEpisode(anime, n);
          report.writeln(
            '  EP$n providers=${res.providers.length} matchedUnavailable=${res.matchedUnavailable} notFound=${res.notFound} -> '
            '${res.providers.entries.map((e) => '${e.key.name}(${e.value.length})').join(", ")}',
          );
        }
      }

      File('/home/jabs/codes-ai/goanime-tv/.qa/path_probe.txt')
          .writeAsStringSync(report.toString());
      // ignore: avoid_print
      print(report.toString());
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}