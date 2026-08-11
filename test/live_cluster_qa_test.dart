// Live QA probe for the acceptance-criteria animes (NOT CI). Run:
//   flutter test test/live_cluster_qa_test.dart --dart-define=LIVE=1
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/animesonline_adapter.dart';

void main() {
  final live = const String.fromEnvironment('LIVE') == '1';
  test('LIVE cluster QA animes', timeout: const Timeout(Duration(minutes: 5)), () async {
    if (!live) return;
    HttpOverrides.global = null;

    final report = StringBuffer();
    final adapter = AnimesOnlineAdapter(source: AnimeSource.animesOnlineCloud);
    final cases = [
      ('Kimetsu no Yaiba', [1]),
      ('Naruto', [1, 220]),
      ('One Piece', [1, 100]),
    ];
    for (final (query, epNos) in cases) {
      report.writeln('\n===== QUERY: $query ($epNos) =====');
      try {
        final res = await adapter.search(query);
        if (res is! Success<List<Anime>> || res.data.isEmpty) {
          report.writeln('  search FAIL');
          continue;
        }
        report.writeln('  candidates: ${res.data.map((a) => a.name).toList()}');
        // Mirror the app flow: resolve the provider page from the CATALOG name
        // (AniList), not from the first raw search card (which may be a movie).
        final match = await adapter.resolveAnime(Anime(name: query, url: ''));
        if (match == null) {
          final again = await adapter.search(query);
          report.writeln(
              '  resolveAnime FAIL; re-search = ${again is Success<List<Anime>> ? again.data.map((a) => a.name).toList() : (again as Failure<List<Anime>>).error.message}');
          continue;
        }
        report.writeln('  resolved: ${match.name} ${match.url}');
        final eps = await adapter.getEpisodes(match);
        if (eps is! Success<List<Episode>>) {
          report.writeln('  getEpisodes FAIL');
          continue;
        }
        report.writeln('  episodes: ${eps.data.length} (1..${eps.data.last.number})');
        for (final n in epNos) {
          final target = eps.data.where((e) => int.tryParse(e.number) == n);
          if (target.isEmpty) {
            report.writeln('  EP$n not listed');
            continue;
          }
          final vs = await adapter.getVideoSources(target.first, anime: match);
          if (vs is Success<List<VideoSource>>) {
            report.writeln('  EP$n OK -> ${vs.data.map((v) => v.url).join(" | ")}');
          } else {
            report.writeln('  EP$n FAIL: ${(vs as Failure).error.message}');
          }
        }
      } catch (e) {
        report.writeln('  EXC: $e');
      }
    }
    // ignore: avoid_print
    print(report.toString());
    File('/home/jabs/codes-ai/goanime-tv/.qa/cluster_qa.txt')
        .writeAsStringSync(report.toString());
  });
}