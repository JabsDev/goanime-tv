import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/scraper/anime_scraper.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

void main() {
  test(
      'getEpisodes with anilistId != null terminates and returns EpisodesResult',
      () async {
    final anime = Anime(
      name: 'Naruto',
      url: 'https://animefire.vip/animes/naruto-todos-os-episodios',
      source: AnimeSource.animeFire,
      anilistId: 20,
    );

    // Regression for QA_REPORT_infinite_loop: the old AniList retry `while`
    // loop never advanced `anilistAttempts` on failure, so this hung forever.
    final result = await AnimeScraper.getEpisodes(anime)
        .timeout(const Duration(seconds: 60));

    expect(result, isA<EpisodesResult>());
  });
}