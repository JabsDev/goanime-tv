// Live probe (NOT part of CI): exercises search/getEpisodes/getVideoSources for
// every implemented source against the real sites, for the 4 QA animes and
// beginning/middle/end episodes. Requires network. Run:
//   flutter test test/live_sources_probe_test.dart --dart-define=LIVE=1
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/source_registry.dart';

const _animes = [
  'One Piece',
  'Black Clover',
  'Black Butler',
  'Haibane Renmei',
];

void main() {
  final live = const String.fromEnvironment('LIVE') == '1';
  test('LIVE backend probe all sources x 4 anime', () async {
    if (!live) return; // no-op unless LIVE=1

    // Android TV Flutter tests run on a headless HTTP client; allow real IO.
    HttpOverrides.global = null;

    final report = StringBuffer();

    for (final query in _animes) {
      report.writeln('\n===== ANIME: $query =====');
      final adapters = SourceRegistry.adapters.where((a) => a.implemented);

      // 1) SEARCH per source
      final found = <String, List<Anime>>{};
      for (final a in adapters) {
        try {
          final res = await a.search(query);
          switch (res) {
            case Success(data: final list):
              found[a.source.name] = list;
              report.writeln(
                  '  [${a.source.name}] search OK: ${list.length} results. '
                  'first=${list.firstOrNull?.name}');
            case Failure(error: final err):
              report.writeln('  [${a.source.name}] search FAIL: ${err.message}');
            case Loading():
              break;
          }
        } catch (e) {
          report.writeln('  [${a.source.name}] search EXC: $e');
        }
      }

      // 2) MATCH + EPISODE-VIDEO via the new on-demand contract
      //    (resolveAnime once per provider → resolveVideo per episode N).
      for (final a in adapters) {
        final list = found[a.source.name];
        if (list == null || list.isEmpty) {
          report.writeln('  [${a.source.name}] skipped (no search result)');
          continue;
        }
        final best = list.first;
        try {
          final match = await a.resolveAnime(best);
          if (match == null) {
            report.writeln('  [${a.source.name}] resolveAnime FAIL (no match)');
            continue;
          }
          report.writeln('  [${a.source.name}] resolveAnime OK: ${match.url}');
          final picks = [1, 5, 10, 15, 20];
          for (final n in picks) {
            try {
              final vs = await a.resolveVideo(match, n);
              report.writeln(
                  '  [${a.source.name}] EP$n video: ${vs.length} sources: '
                  '${vs.map((v) => '${v.quality} ${_host(v.url)}').join(", ")}');
            } catch (ex) {
              report.writeln('  [${a.source.name}] EP$n video EXC: $ex');
            }
          }
        } catch (e) {
          report.writeln('  [${a.source.name}] resolveAnime EXC: $e');
        }
      }
    }

    // ignore: avoid_print
    print(report.toString());
    File('/home/jabs/codes-ai/goanime-tv/.qa/sources_probe.txt')
        .writeAsStringSync(report.toString());
  });
}

String _host(String url) {
  try {
    return Uri.parse(url).host.replaceFirst('www.', '');
  } catch (_) {
    return '?';
  }
}
