import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/scraper/anime_scraper.dart';
import 'package:goanime_tv/data/models/anime.dart';

void main() {
  group('AnimeScraper.normalize', () {
    test('lowercases string', () {
      expect(AnimeScraper.normalize('Naruto Shippuden'), 'naruto shippuden');
    });

    test('folds accents', () {
      expect(
        AnimeScraper.normalize('áàãâäéèêëíìîïóòõôöúùûüç'),
        'aaaaaeeeeiiiiooooouuuuc',
      );
      expect(AnimeScraper.normalize('Náruto'), 'naruto');
    });

    test('removes qualifier tokens', () {
      expect(AnimeScraper.normalize('One Piece Dublado'), 'one piece');
      expect(AnimeScraper.normalize('Naruto Legendado'), 'naruto');
      expect(AnimeScraper.normalize('Attack on Titan Dub'), 'attack on titan');
      expect(AnimeScraper.normalize('Bleach Sub'), 'bleach');
      expect(
        AnimeScraper.normalize('Naruto todos os episodios'),
        'naruto',
      );
    });

    test('replaces non-alphanumeric chars with spaces', () {
      expect(AnimeScraper.normalize('naruto-shippuden!!'), 'naruto shippuden');
    });

    test('collapses whitespace and trims', () {
      expect(
        AnimeScraper.normalize('  naruto   shippuden  '),
        'naruto shippuden',
      );
    });

    test('handles empty string', () {
      expect(AnimeScraper.normalize(''), '');
    });
  });

  group('AnimeScraper.bestMatch', () {
    Anime makeAnime(String name,
        {AnimeSource source = AnimeSource.animeFire,
        String url = '',
        String? allAnimeId,
        String? superFlixTmdbId}) {
      return Anime(
        name: name,
        url: url,
        source: source,
        allAnimeId: allAnimeId,
        superFlixTmdbId: superFlixTmdbId,
      );
    }

    test('exact match gets highest score', () {
      final candidates = [
        makeAnime('Naruto Shippuden'),
        makeAnime('Naruto'),
        makeAnime('Boruto'),
      ];
      final result = AnimeScraper.bestMatch(
        'Naruto Shippuden',
        candidates,
        AnimeSource.animeFire,
      );
      expect(result.name, 'Naruto Shippuden');
    });

    test('prefix match scores higher than contains', () {
      final candidates = [
        makeAnime('Naruto Shippuden'),
        makeAnime('Denaruto'),
      ];
      final result = AnimeScraper.bestMatch(
        'naruto',
        candidates,
        AnimeSource.animeFire,
      );
      // 'Naruto Shippuden' starts with 'naruto' → prefix match (+60)
      // 'Denaruto' contains 'naruto' → contains match (+40)
      expect(result.name, 'Naruto Shippuden');
    });

    test('token overlap scoring works', () {
      final candidates = [
        makeAnime('One Piece'),
        makeAnime('Piece by Piece'),
      ];
      final result = AnimeScraper.bestMatch(
        'One Piece',
        candidates,
        AnimeSource.animeFire,
      );
      // 'one piece' starts with 'one piece' → exact match after normalize
      expect(result.name, 'One Piece');
    });

    test('side-token penalty applies', () {
      final candidates = [
        makeAnime('One Piece'),
        makeAnime('One Piece Film Red'),
      ];
      final result = AnimeScraper.bestMatch(
        'One Piece',
        candidates,
        AnimeSource.animeFire,
      );
      // 'One Piece Film Red' contains 'film' → -25 side-token penalty
      // 'One Piece' has no penalty → higher score
      expect(result.name, 'One Piece');
    });

    test('AnimeFire full-series boost applies', () {
      final candidates = [
        makeAnime('Naruto Shippuden',
            url: '/anime/naruto-shippuden'),
        makeAnime('Naruto Shippuden',
            source: AnimeSource.animeFire,
            url: '/anime/naruto-shippuden/todos-os-episodios'),
      ];
      final result = AnimeScraper.bestMatch(
        'Naruto Shippuden',
        candidates,
        AnimeSource.animeFire,
      );
      // Both have exact match scores, but second has +15 boost from 'todos-os-episodios'
      expect(result.url, contains('todos-os-episodios'));
    });

    test('shorter title preferred when scores are similar', () {
      final candidates = [
        makeAnime('Naruto Shippuden: The Lost Story Arc Extended Cut'),
        makeAnime('Naruto Shippuden'),
      ];
      final result = AnimeScraper.bestMatch(
        'Naruto Shippuden',
        candidates,
        AnimeSource.animeFire,
      );
      // Both are prefix matches, but shorter title has smaller diff penalty
      expect(result.name, 'Naruto Shippuden');
    });
  });
}
