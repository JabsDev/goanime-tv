import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/scraper/anime_scraper.dart';
import 'package:goanime_tv/data/models/anime.dart';

/// Regressão do bug que o usuário reportou na v1.5.0: com a chave TMDB ativa
/// a busca de dramas voltava vazia porque (a) o TMDB não estava no fan-out e
/// (b) o filtro de validade descartava todo título com `source: anilist` —
/// que é exatamente o `source` dado aos títulos do TMDB.
void main() {
  group('isOpenable — filtro de resultados', () {
    test('título TMDB (source anilist + tmdbId) PASSA', () {
      final a = Anime(
        name: 'Goblin',
        url: 'https://themoviedb.org/tv/1396',
        source: AnimeSource.anilist,
        tmdbId: 1396,
        mediaType: 'tv',
      );
      expect(AnimeScraper.isOpenable(a), isTrue,
          reason: 'com tmdbId o título é abrível e não pode ser descartado');
    });

    test('AniList puro (sem tmdbId) é descartado', () {
      final a = Anime(
        name: 'Naruto',
        url: 'https://anilist.co/anime/20',
        source: AnimeSource.anilist,
        anilistId: 20,
      );
      expect(AnimeScraper.isOpenable(a), isFalse,
          reason: 'AniList é metadata pura, não tem stream próprio');
    });

    test('fonte de vídeo precisa de URL', () {
      expect(
        AnimeScraper.isOpenable(Anime(
            name: 'X', url: '', source: AnimeSource.animeFire)),
        isFalse,
      );
      expect(
        AnimeScraper.isOpenable(Anime(
            name: 'X', url: 'https://a/1', source: AnimeSource.animeFire)),
        isTrue,
      );
    });

    test('fontes novas da v1.5.0 seguem a mesma regra', () {
      expect(
        AnimeScraper.isOpenable(Anime(
            name: 'Swallowed Star',
            url: 'https://donghuanosekai.com/swallowed-star',
            source: AnimeSource.donghuaNoSekai)),
        isTrue,
      );
      expect(
        AnimeScraper.isOpenable(Anime(
            name: 'Goblin',
            url: 'https://doramasflix.in/dorama/x',
            source: AnimeSource.doramasflix)),
        isTrue,
      );
    });

    test('allAnime exige allAnimeId', () {
      expect(
        AnimeScraper.isOpenable(Anime(
            name: 'X', url: 'https://a/1', source: AnimeSource.allAnime)),
        isFalse,
      );
      expect(
        AnimeScraper.isOpenable(Anime(
            name: 'X',
            url: 'https://a/1',
            source: AnimeSource.allAnime,
            allAnimeId: 'abc')),
        isTrue,
      );
    });
  });
}