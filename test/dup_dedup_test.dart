import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/scraper/anime_scraper.dart';

/// Offline tests for the search dedup (relatorio-busca-duplicidade-fontes
/// _MELHORADO.md, Fase 4a). No network: these exercise the pure identity keys
/// and the two merge passes on hand-built [Anime]s.
void main() {
  Anime anime({
    required String name,
    required String url,
    AnimeSource source = AnimeSource.animeFire,
    int? anilistId,
    String? description,
    String? englishName,
    List<String> genres = const [],
    int? episodes,
  }) =>
      Anime(
        name: name,
        url: url,
        source: source,
        anilistId: anilistId,
        description: description,
        englishName: englishName,
        genres: genres,
        episodes: episodes,
      );

  group('titleIdentityKey', () {
    test('B: dublado vs legendado variants share the same key', () {
      expect(
        AnimeScraper.titleIdentityKey(
            anime(name: 'One Piece Dublado', url: '/one-piece-dublado')),
        AnimeScraper.titleIdentityKey(
            anime(name: 'One Piece', url: '/one-piece')),
      );
    });

    test('D: "– Todos os Episódios" suffix and accent fold to the base key', () {
      expect(
        AnimeScraper.titleIdentityKey(
            anime(name: 'Black Clover – Todos os Episódios', url: '/bc-todos')),
        AnimeScraper.titleIdentityKey(
            anime(name: 'black clover', url: '/bc')),
      );
    });

    test('C4: badge "N/A A14" is stripped from the title key', () {
      expect(
        AnimeScraper.titleIdentityKey(
            anime(name: 'One Piece Film: Red N/A A14', url: '/red-a14')),
        AnimeScraper.titleIdentityKey(
            anime(name: 'One Piece Film: Red', url: '/red')),
      );
      expect(
        AnimeScraper.titleIdentityKey(
            anime(name: 'Black Clover: Mahou Tei no Ken N/A A14', url: '/mkn-a14')),
        AnimeScraper.titleIdentityKey(
            anime(name: 'Black Clover: Mahou Tei no Ken', url: '/mkn')),
      );
    });

    test('C3: "One Piece –" collapses into "One Piece"', () {
      expect(
        AnimeScraper.titleIdentityKey(anime(name: 'One Piece –', url: '/op')),
        AnimeScraper.titleIdentityKey(anime(name: 'One Piece', url: '/op2')),
      );
    });

    test('drift offline: Shippuden vs Shippuuden stay distinct keys', () {
      expect(
        AnimeScraper.titleIdentityKey(
            anime(name: 'Naruto Shippuden', url: '/n-shippuden')),
        isNot(AnimeScraper.titleIdentityKey(
            anime(name: 'Naruto Shippuuden', url: '/n-shippuuden'))),
      );
    });

    test('C12: punctuation-only name yields a non-empty key', () {
      final key =
          AnimeScraper.titleIdentityKey(anime(name: '&*#(!)', url: '/x'));
      expect(key, isNotEmpty);
      expect(AnimeScraper.titleIdentityKey(anime(name: '', url: '/x')), '/x');
    });
  });

  test('B: two AnimeFire variants dedup to one representative (lowest index)',
      () {
    final rep = AnimeScraper.dedupeByTitle([
      anime(name: 'One Piece Dublado', url: '/one-piece-dublado'),
      anime(name: 'One Piece', url: '/one-piece'),
    ]);
    expect(rep.length, 1);
    expect(rep.single.url, '/one-piece-dublado');
  });

  test('C3: same-title cluster (id) and series (id) collapse to one card', () {
    final rep = AnimeScraper.dedupeByTitle([
      for (var i = 0; i < 9; i++)
        anime(name: 'One Piece', url: '/op$i', source: AnimeSource.goyabu),
      for (var i = 0; i < 6; i++)
        anime(
          name: 'One Piece –',
          url: '/opc$i',
          source: AnimeSource.animesDrive,
          anilistId: 171630,
        ),
      anime(name: 'One Piece', url: '/op-af', anilistId: 21),
    ]);
    expect(rep.length, 1);
    expect(rep.single.anilistId, 21); // 171630 of the merged member dropped on purpose
    expect(rep.single.source, AnimeSource.animeFire); // priority ties -> first in array
  });

  test('representative: lower priority source wins over higher index', () {
    final rep = AnimeScraper.dedupeByTitle([
      anime(name: 'Solo Leveling', url: '/sl-g', source: AnimeSource.goyabu),
      anime(name: 'Solo Leveling', url: '/sl-af', source: AnimeSource.animeFire),
    ]);
    expect(rep.single.source, AnimeSource.animeFire);
  });

  test('Fusão B: same anilistId merges, metadata propagates with ??=', () {
    final merged = AnimeScraper.mergeByAnilistId([
      anime(
        name: 'Naruto Shippuden',
        url: '/shippuden',
        source: AnimeSource.goyabu,
        anilistId: 1735,
        genres: ['Action'],
        episodes: 500,
      ),
      anime(
        name: 'Naruto Shippuuden',
        url: '/shippuuden',
        source: AnimeSource.animesDrive,
        anilistId: 1735,
      ),
      anime(
        name: 'Naruto',
        url: '/naruto',
        source: AnimeSource.animeFire,
        anilistId: null,
      ),
    ]);
    expect(merged.length, 2);
    final shippuden = merged.firstWhere((a) => a.name.contains('Shippuden'));
    expect(shippuden.genres, ['Action']);
    expect(shippuden.episodes, 500);
  });

  test('Fusão B never overwrites good value with null', () {
    final merged = AnimeScraper.mergeByAnilistId([
      anime(
        name: 'One Piece',
        url: '/op',
        anilistId: 21,
        genres: ['Adventure'],
      ),
      anime(
        name: 'One Piece Film',
        url: '/op-film',
        anilistId: 21,
        genres: [],
        description: null,
      ),
    ]);
    final rep = merged.single;
    expect(rep.genres, ['Adventure']); // empty list treated as missing
    expect(rep.description, isNull); // good value not overwritten by null
  });
}