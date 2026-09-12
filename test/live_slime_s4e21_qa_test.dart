// Live QA (NOT part of CI): Slime S4E21 season-resolution against the REAL
// sites, using the PATCHED adapters (no mocks). Requires network. Run:
//   flutter test test/live_slime_s4e21_qa_test.dart --dart-define=LIVE=1
// Asserts only what the app controls (parse + season routing); video
// extraction itself (Blogger/CDN liveness) is reported, not asserted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/anime_source_adapter.dart';
import 'package:goanime_tv/core/sources/dooplay_adapter.dart';
import 'package:goanime_tv/core/sources/goyabu_adapter.dart';

const _s4CatalogName = 'Tensei Shitara Slime Datta Ken 4th Season';

void main() {
  final live = const String.fromEnvironment('LIVE') == '1';
  test('LIVE Slime S4E21 QA (BetterAnime + Goyabu + bestMatch)',
      timeout: const Timeout(Duration(minutes: 5)), () async {
    if (!live) return; // no-op unless LIVE=1
    HttpOverrides.global = null;
    final report = StringBuffer();

    // 1) BetterAnime combined page through the PATCHED DooPlayAdapter.
    final dooplay = DooPlayAdapter(source: AnimeSource.betterAnime);
    final page = Anime(
      name: 'Slime',
      url: 'https://betteranime.io/animes/tensei-shitara-slime-datta-ken/',
      source: AnimeSource.betterAnime,
    );
    final epsRes = await dooplay.getEpisodes(page);
    switch (epsRes) {
      case Success(data: final eps):
        final e21 = eps.where((e) => e.number == '21').toList();
        report.writeln(
            '[betterAnime] episodes=${eps.length} number-21 x${e21.length} '
            'seasons=${e21.map((e) => e.season).toList()}');
        expect(e21.map((e) => e.season).toSet(), containsAll([2, 3, 4]),
            reason: 'combined page must expose per-season 21s');
        expect(
            e21.map((e) => e.url),
            contains(
                'https://betteranime.io/episodios/tensei-shitara-slime-datta-ken-4-episodio-21/'));
      case Failure(error: final err):
        report.writeln('[betterAnime] getEpisodes FAIL: ${err.message}');
        fail('betterAnime page unreachable: ${err.message}');
      case Loading():
        break;
    }

    // 2) Goyabu: S4 page state (19 eps on 11/09/2026 → E21 = []).
    final goyabu = GoyabuAdapter();
    final s4 = Anime(
      name: 'Slime S4',
      url: 'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-4',
      source: AnimeSource.goyabu,
    );
    final gRes = await goyabu.getEpisodes(s4);
    switch (gRes) {
      case Success(data: final eps):
        report.writeln('[goyabu] S4 episodes=${eps.length} '
            'has21=${eps.any((e) => e.number == '21')}');
      case Failure(error: final err):
        report.writeln('[goyabu] getEpisodes FAIL: ${err.message}');
      case Loading():
        break;
    }

    // 3) bestMatch pins the season page on live search results.
    final search = await goyabu.search('slime');
    switch (search) {
      case Success(data: final cands):
        final pick = AnimeSourceAdapter.bestMatch(
            _s4CatalogName, List.of(cands), AnimeSource.goyabu);
        report.writeln('[goyabu] bestMatch S4 → ${pick.url}');
        expect(pick.url, contains('-4'),
            reason: 'S4 query must pin the season page, not the base');
      case Failure(error: final err):
        report.writeln('[goyabu] search FAIL: ${err.message}');
      case Loading():
        break;
    }

    // ignore: avoid_print
    print(report.toString());
    final out = File('.qa/slime_s4e21_qa.txt');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(report.toString());
  });
}
