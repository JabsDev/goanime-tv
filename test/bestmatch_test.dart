import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/sources/anime_source_adapter.dart';

/// Regression tests for [AnimeSourceAdapter.bestMatch]. The original bug: a
/// spin-off whose URL carries the "todos-os-episodios" slug got the +15
/// full-series bonus and beat the actual main series. The bonus now only fires
/// on an exact title match, so the series always wins.
void main() {
  List<Anime> _candidates() => [
        Anime(
          name: 'Koisuru One Piece',
          url: 'https://animefire.io/animes/koisuru-one-piece-todos-os-episodios',
          source: AnimeSource.animeFire,
        ),
        Anime(
          name: 'One Piece Film: Red',
          url: 'https://animefire.io/animes/one-piece-film-red-dublado-todos-os-episodios',
          source: AnimeSource.animeFire,
        ),
        Anime(
          name: 'One Piece',
          url: 'https://animefire.io/animes/one-piece-dublado-todos-os-episodios',
          source: AnimeSource.animeFire,
        ),
        Anime(
          name: 'One Piece',
          url: 'https://animefire.io/animes/one-piece-todos-os-episodios',
          source: AnimeSource.animeFire,
        ),
      ];

  test('main series beats spin-off that shares the todos-os-episodios slug',
      () {
    final pick =
        AnimeSourceAdapter.bestMatch('One Piece', _candidates(), AnimeSource.animeFire);
    expect(pick.url, 'https://animefire.io/animes/one-piece-todos-os-episodios');
    expect(pick.name, 'One Piece');
  });

  test('movie/film candidate never wins against the exact series', () {
    final pick =
        AnimeSourceAdapter.bestMatch('One Piece', _candidates(), AnimeSource.animeFire);
    expect(pick.url.contains('film'), isFalse);
  });

  test('exact match outranks a prefix-even spin-off', () {
    // Even when the query is a substring of the spin-off title, the main
    // series' exact match must win.
    final only = <Anime>[
      Anime(
        name: 'One Piece: Episode of Luffy',
        url: 'https://animefire.io/animes/one-piece-episode-of-luffy-todos-os-episodios',
        source: AnimeSource.animeFire,
      ),
      Anime(
        name: 'One Piece',
        url: 'https://animefire.io/animes/one-piece-dublado-todos-os-episodios',
        source: AnimeSource.animeFire,
      ),
    ];
    final pick =
        AnimeSourceAdapter.bestMatch('One Piece', only, AnimeSource.animeFire);
    expect(pick.name, 'One Piece');
  });

  test('other sources (non-AnimeFire) still resolve a plain exact match',
      () {
    final cands = <Anime>[
      Anime(
        name: 'One Piece: Gyojin Tou-hen',
        url: 'https://goyabu.io/anime/one-piece',
        source: AnimeSource.goyabu,
      ),
      Anime(
        name: 'One Piece',
        url: 'https://goyabu.io/anime/one-piece',
        source: AnimeSource.goyabu,
      ),
    ];
    final pick =
        AnimeSourceAdapter.bestMatch('One Piece', cands, AnimeSource.goyabu);
    expect(pick.name, 'One Piece');
  });
}