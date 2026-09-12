import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/sources/anime_source_adapter.dart';
import 'package:goanime_tv/core/utils/text_utils.dart';

/// Shared season-hint contract (revisao-critica §2.3 item 10): every adapter
/// extracts the season from the SAME neutral owner ([TextUtils.seasonOf]) and
/// from candidate URLs via [AnimeSourceAdapter.seasonOfCandidateUrl]. One
/// table here pins the behaviour for all providers — no silent divergence.
void main() {
  group('TextUtils.seasonOf (query/catalog titles)', () {
    test('season keywords', () {
      expect(
          TextUtils.seasonOf('Tensei Shitara Slime Datta Ken 4th Season'), 4);
      expect(
          TextUtils.seasonOf(
              'That Time I Got Reincarnated as a Slime Season 2'),
          2);
      expect(TextUtils.seasonOf('Black Clover 2nd Season'), 2);
      expect(TextUtils.seasonOf('Black Clover 1st Season'), 1);
      expect(TextUtils.seasonOf('Naruto Season 10'), 10);
    });

    test('compact + PT-BR variants', () {
      expect(TextUtils.seasonOf('Slime S4'), 4);
      expect(TextUtils.seasonOf('Slime T4'), 4);
      expect(TextUtils.seasonOf('Naruto Temporada 2'), 2);
      expect(TextUtils.seasonOf('Naruto 2ª Temporada'), 2);
    });

    test('negatives: never a season', () {
      // Bare trailing integers are something else (NOT seasons) — no
      // generic trailing-number matching, by design.
      expect(TextUtils.seasonOf('86'), isNull);
      expect(TextUtils.seasonOf('Black Clover'), isNull);
      expect(TextUtils.seasonOf(
          'That Time I Got Reincarnated as a Slime'), isNull);
      expect(TextUtils.seasonOf('Tensei shitara Slime Datta Ken 4'), isNull);
      expect(TextUtils.seasonOf('Filme 2'), isNull);
      expect(TextUtils.seasonOf('Naruto 20'), isNull);
      expect(TextUtils.seasonOf('One Piece Film: Red'), isNull);
      // The bare S/T token must be standalone: "first 2" is not season 2.
      expect(TextUtils.seasonOf('First 2'), isNull);
    });
  });

  group('AnimeSourceAdapter.seasonOfCandidateUrl (provider page tails)', () {
    test('season-position tails', () {
      expect(
          AnimeSourceAdapter.seasonOfCandidateUrl(
              'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-4'),
          4);
      expect(
          AnimeSourceAdapter.seasonOfCandidateUrl(
              'https://goyabu.io/anime/tensei-shitara-slime-datta-ken-4/'),
          4);
      expect(
          AnimeSourceAdapter.seasonOfCandidateUrl(
              'https://site.cc/anime/naruto-2?x=1'),
          2);
    });

    test('non-season tails never match', () {
      expect(AnimeSourceAdapter.seasonOfCandidateUrl(
          'https://goyabu.io/anime/one-piece'), isNull);
      expect(AnimeSourceAdapter.seasonOfCandidateUrl(
          'https://site.cc/anime/15859'), isNull);
      expect(AnimeSourceAdapter.seasonOfCandidateUrl(
          'https://site.cc/anime/naruto-720p'), isNull);
      // Suffix digit after a non-season token is not a season.
      expect(AnimeSourceAdapter.seasonOfCandidateUrl(
          'https://site.cc/anime/naruto-online-hd-2'), isNull);
      expect(AnimeSourceAdapter.seasonOfCandidateUrl(
          'https://site.cc/anime/naruto-dublado-2'), isNull);
      // Episode-style tails are episodes, not seasons.
      expect(AnimeSourceAdapter.seasonOfCandidateUrl(
          'https://betteranime.io/episodios/slime-4-episodio-21'), isNull);
      // 3+ digit tails are IDs/years, not seasons.
      expect(AnimeSourceAdapter.seasonOfCandidateUrl(
          'https://site.cc/anime/naruto-2024'), isNull);
    });
  });
}
