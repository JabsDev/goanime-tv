// Live probe for the AnimesOnline cluster (NOT CI): run:
//   flutter test test/live_cluster_probe_test.dart --dart-define=LIVE=1
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/animesonline_adapter.dart';

void main() {
  final live = const String.fromEnvironment('LIVE') == '1';
  test('LIVE cluster probe', timeout: const Timeout(Duration(minutes: 5)), () async {
    if (!live) return;
    HttpOverrides.global = null;

    final report = StringBuffer();

    for (final source in [
      AnimeSource.animesOnlineCloud,
      AnimeSource.animesDrive,
      AnimeSource.animeQ,
      AnimeSource.animePlay,
    ]) {
      final adapter = AnimesOnlineAdapter(source: source);
      report.writeln('\n===== ${adapter.baseUrl} =====');
      try {
        final res = await adapter.search('solo leveling');
        if (res is Success<List<Anime>> && res.data.isNotEmpty) {
          report.writeln('  search OK: ${res.data.length} -> ${res.data.first.name}');
          final match = await adapter.resolveAnime(res.data.first);
          if (match == null) {
            report.writeln('  resolveAnime FAIL');
            continue;
          }
          report.writeln('  resolved: ${match.name} ${match.url}');
          final eps = await adapter.getEpisodes(match);
          if (eps is Success<List<Episode>> && eps.data.isNotEmpty) {
            report.writeln('  episodes OK: ${eps.data.length} (first=${eps.data.first.number})');
            final ep = eps.data.first;
            final vs = await adapter.getVideoSources(ep, anime: match);
            if (vs is Success<List<VideoSource>>) {
              report.writeln('  EP${ep.number} video:');
              for (final v in vs.data) {
                report.writeln('    [${v.quality}] ${v.url}');
              }
            } else {
              report.writeln('  EP video FAIL: ${(vs as Failure).error.message}');
            }
          } else {
            report.writeln('  getEpisodes FAIL');
          }
        } else {
          report.writeln('  search FAIL: ${(res as Failure).error.message}');
        }
      } catch (e) {
        report.writeln('  EXC: $e');
      }
    }

    // ignore: avoid_print
    print(report.toString());
    File('/home/jabs/codes-ai/goanime-tv/.qa/cluster_probe.txt')
        .writeAsStringSync(report.toString());
  });
}