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

  test('hentai candidate never wins when the query has no hentai', () {
    final cands = <Anime>[
      Anime(
        name: 'Naruto Hentai',
        url: 'https://animeplayer.com.br/anime/naruto-hentai',
        source: AnimeSource.animePlayer,
      ),
      Anime(
        name: 'Naruto',
        url: 'https://animeplayer.com.br/anime/naruto',
        source: AnimeSource.animePlayer,
      ),
    ];
    final pick = AnimeSourceAdapter.bestMatch(
        'Naruto', cands, AnimeSource.animePlayer);
    expect(pick.name, 'Naruto');
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

  // Slime S4 (relatorio-slime-s4e21 §4b): base (S1) vs `…-4` tied 59×59 for
  // the S4 query — the season bonus must pin the season page, deterministically.
  List<Anime> _slimeCandidates() => [
        Anime(
          name: 'Tensei Shitara Slime Datta Ken',
          url: 'https://goyabu.io/anime/tensei-shitara-slime-datta-ken',
          source: AnimeSource.goyabu,
        ),
        Anime(
          name: 'Tensei Shitara Slime Datta Ken 3',
          url: 'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-3',
          source: AnimeSource.goyabu,
        ),
        Anime(
          name: 'Tensei Shitara Slime Datta Ken 4',
          url: 'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-4',
          source: AnimeSource.goyabu,
        ),
      ];

  test('Slime 4th Season query pins the …-4 page (was 59×59 tie)', () {
    final pick = AnimeSourceAdapter.bestMatch(
      'Tensei Shitara Slime Datta Ken 4th Season',
      _slimeCandidates(),
      AnimeSource.goyabu,
    );
    expect(pick.url,
        'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-4');
  });

  test('Slime 3rd Season query pins the …-3 page', () {
    final pick = AnimeSourceAdapter.bestMatch(
      'Tensei Shitara Slime Datta Ken 3rd Season',
      _slimeCandidates(),
      AnimeSource.goyabu,
    );
    expect(pick.url,
        'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-3');
  });

  test('Slime query without season keeps legacy behaviour (base wins)', () {
    final pick = AnimeSourceAdapter.bestMatch(
      'Tensei Shitara Slime Datta Ken',
      _slimeCandidates(),
      AnimeSource.goyabu,
    );
    expect(pick.url,
        'https://goyabu.io/anime/tensei-shitara-slime-datta-ken');
  });

  test('season tiebreak is deterministic (3 runs, any input order)', () {
    const query = 'Tensei Shitara Slime Datta Ken 4th Season';
    for (var i = 0; i < 3; i++) {
      final cands = _slimeCandidates()..shuffle();
      final pick =
          AnimeSourceAdapter.bestMatch(query, cands, AnimeSource.goyabu);
      expect(pick.url,
          'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-4');
    }
  });

  test('season bonus never outranks an exact title match', () {
    // Query without season hint: a season-suffixed page must not steal an
    // exact base-title match (scores unchanged when hint is null).
    final cands = <Anime>[
      Anime(
        name: 'Naruto',
        url: 'https://goyabu.io/anime/naruto-2',
        source: AnimeSource.goyabu,
      ),
      Anime(
        name: 'Naruto',
        url: 'https://goyabu.io/anime/naruto',
        source: AnimeSource.goyabu,
      ),
    ];
    final pick =
        AnimeSourceAdapter.bestMatch('Naruto', cands, AnimeSource.goyabu);
    expect(pick.url, 'https://goyabu.io/anime/naruto');
  });
}