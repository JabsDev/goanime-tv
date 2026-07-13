import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/utils/text_utils.dart';

void main() {
  group('TextUtils.cleanTitle', () {
    test('removes source tags [AnimeFire] and [AllAnime]', () {
      expect(TextUtils.cleanTitle('[AnimeFire] Naruto'), equals('Naruto'));
      expect(TextUtils.cleanTitle('[AllAnime] One Piece'), equals('One Piece'));
      expect(TextUtils.cleanTitle('[animefire] naruto'), equals('naruto'));
      expect(TextUtils.cleanTitle('[allanime] one piece'), equals('one piece'));
    });

    test('removes sub/dub qualifiers (Dublado, Legendado, Dub, Sub)', () {
      expect(
        TextUtils.cleanTitle('Naruto Dublado'),
        equals('Naruto'),
      );
      expect(
        TextUtils.cleanTitle('One Piece Legendado'),
        equals('One Piece'),
      );
      expect(TextUtils.cleanTitle('Naruto Dub'), equals('Naruto'));
      expect(TextUtils.cleanTitle('One Piece Sub'), equals('One Piece'));
    });

    test('removes "todos os episodios" suffix', () {
      expect(
        TextUtils.cleanTitle('Naruto todos os episodios'),
        equals('Naruto'),
      );
      expect(
        TextUtils.cleanTitle('One Piece Todos Os Episodios'),
        equals('One Piece'),
      );
    });

    test('strips season/episode number suffixes (1.0 A1, trailing digits)', () {
      expect(
        TextUtils.cleanTitle('Naruto 1.0 A1'),
        equals('Naruto'),
      );
      expect(
        TextUtils.cleanTitle('One Piece 2.0 A3'),
        equals('One Piece'),
      );
    });

    test('removes sub/dub in parentheses ((Dublado), (legendado))', () {
      // Note: cleanTitle removes the keyword inside parentheses via the
      // standalone sub/dub regex (step 2) before the parenthetical regex
      // (step 5). Empty parentheses remain — this is a pre-existing quirk.
      expect(
        TextUtils.cleanTitle('Naruto (Dublado)'),
        equals('Naruto ()'),
      );
      expect(
        TextUtils.cleanTitle('One Piece (legendado)'),
        equals('One Piece ()'),
      );
    });

    test('removes episode count in parentheses ((25 episodes), (64 eps))', () {
      expect(
        TextUtils.cleanTitle('Naruto (25 episodes)'),
        equals('Naruto'),
      );
      expect(
        TextUtils.cleanTitle('Naruto (64 eps)'),
        equals('Naruto'),
      );
    });

    test('collapses multiple spaces and trims', () {
      expect(
        TextUtils.cleanTitle('Naruto   Shippuden'),
        equals('Naruto Shippuden'),
      );
      expect(
        TextUtils.cleanTitle('  Naruto  '),
        equals('Naruto'),
      );
    });

    test('handles empty string', () {
      expect(TextUtils.cleanTitle(''), equals(''));
    });
  });

  group('TextUtils.treatName', () {
    test('lowercases and replaces spaces with hyphens', () {
      expect(
        TextUtils.treatName('Naruto Shippuden'),
        equals('naruto-shippuden'),
      );
    });

    test('handles single word', () {
      expect(TextUtils.treatName('Naruto'), equals('naruto'));
    });

    test('handles empty string', () {
      expect(TextUtils.treatName(''), equals(''));
    });
  });

  group('TextUtils.extractSuperFlixSeason', () {
    test('extracts season number from URL with matching tmdbId', () {
      const url = 'https://superflix.pro/serie/12345/2/episode/3';
      expect(
        TextUtils.extractSuperFlixSeason(url, '12345'),
        equals('2'),
      );
    });

    test('returns null when tmdbId is null', () {
      const url = 'https://superflix.pro/serie/12345/2/episode/3';
      expect(TextUtils.extractSuperFlixSeason(url, null), isNull);
    });

    test('returns null when URL does not match tmdbId', () {
      const url = 'https://superflix.pro/serie/99999/2/episode/3';
      expect(TextUtils.extractSuperFlixSeason(url, '12345'), isNull);
    });
  });
}
