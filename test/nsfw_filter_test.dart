import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/utils/nsfw_filter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/anilist_models.dart';

Anime _anime({
  String name = 'Naruto',
  bool? isAdult,
  List<String> genres = const [],
}) {
  return Anime(
    name: name,
    url: '',
    source: AnimeSource.animeFire,
    isAdult: isAdult,
    genres: genres,
  );
}

void main() {
  group('classify', () {
    test('isAdult true => hentai (canonical signal)', () {
      expect(NsfwFilter.classify(_anime(name: 'Sei Gensou', isAdult: true)),
          NsfwLevel.hentai);
    });

    test('genre Ecchi => ecchi (lighter than hentai)', () {
      expect(NsfwFilter.classify(_anime(name: 'To Love Ru', genres: ['Ecchi', 'Romance'])),
          NsfwLevel.ecchi);
    });

    test('genre ecchi lowercase is normalized', () {
      expect(NsfwFilter.classify(_anime(name: 'X', genres: ['ecchi'])),
          NsfwLevel.ecchi);
    });

    test('tag Fan Service => ecchi', () {
      final level = NsfwFilter.classifySignals(
        isAdult: false,
        genres: const [],
        tags: const ['Fan Service'],
        title: 'X',
      );
      expect(level, NsfwLevel.ecchi);
    });

    test('hentai no title fallback for un-enriched results', () {
      expect(NsfwFilter.classify(_anime(name: 'Hentai XXX 1')), NsfwLevel.hentai);
    });

    test('safe anime => safe', () {
      expect(NsfwFilter.classify(_anime()), NsfwLevel.safe);
    });

    test('eromanga (contains ero) is NOT hentai', () {
      expect(NsfwFilter.classify(_anime(name: 'Eromanga Sensei')),
          NsfwLevel.safe);
    });

    test('ecchi genre does not override isAdult (hentai wins)', () {
      expect(
          NsfwFilter.classify(
              _anime(name: 'X', isAdult: true, genres: ['Ecchi'])),
          NsfwLevel.hentai);
    });
  });

  group('shouldShow / levelAllowed', () {
    final safe = _anime(name: 'Naruto');
    final ecchi = _anime(name: 'To Love Ru', genres: ['Ecchi']);
    final hentai = _anime(name: 'Sei Gensou', isAdult: true);

    test('strict hides ecchi and hentai', () {
      expect(NsfwFilter.shouldShow(safe, NsfwFilterSetting.strict), isTrue);
      expect(NsfwFilter.shouldShow(ecchi, NsfwFilterSetting.strict), isFalse);
      expect(NsfwFilter.shouldShow(hentai, NsfwFilterSetting.strict), isFalse);
    });

    test('soft hides only hentai', () {
      expect(NsfwFilter.shouldShow(safe, NsfwFilterSetting.soft), isTrue);
      expect(NsfwFilter.shouldShow(ecchi, NsfwFilterSetting.soft), isTrue);
      expect(NsfwFilter.shouldShow(hentai, NsfwFilterSetting.soft), isFalse);
    });

    test('off shows everything', () {
      expect(NsfwFilter.shouldShow(safe, NsfwFilterSetting.off), isTrue);
      expect(NsfwFilter.shouldShow(ecchi, NsfwFilterSetting.off), isTrue);
      expect(NsfwFilter.shouldShow(hentai, NsfwFilterSetting.off), isTrue);
    });
  });

  group('filter', () {
    test('off returns the same list', () {
      final list = [_anime(), _anime(name: 'X', isAdult: true)];
      expect(NsfwFilter.filter(list, NsfwFilterSetting.off), same(list));
    });

    test('strict removes ecchi and hentai, keeps safe', () {
      final list = [
        _anime(name: 'A'),
        _anime(name: 'B', genres: ['Ecchi']),
        _anime(name: 'C', isAdult: true),
      ];
      final out = NsfwFilter.filter(list, NsfwFilterSetting.strict);
      expect(out.map((a) => a.name), ['A']);
    });
  });

  group('classifyMedia (AniList user lists)', () {
    test('isAdult and genres come from media', () {
      final media = AniListMedia(
        id: 1,
        title: 'X',
        isAdult: true,
        genres: const ['Ecchi'],
      );
      expect(NsfwFilter.classifyMedia(media), NsfwLevel.hentai);
    });
  });

  group('classifyStoredItem (favorites/history)', () {
    test('uses detail when present', () {
      final detail = AniListMediaDetail(
        id: 1,
        isAdult: true,
        genres: const [],
        tags: const [],
        coverImage: AniListCoverImage.fromJson(const {}),
      );
      expect(NsfwFilter.classifyStoredItem(title: 'X', detail: detail),
          NsfwLevel.hentai);
    });

    test('falls back to title keyword when detail is null', () {
      expect(NsfwFilter.classifyStoredItem(title: 'Hentai 1'), NsfwLevel.hentai);
      expect(NsfwFilter.classifyStoredItem(title: 'Naruto'), NsfwLevel.safe);
    });
  });
}
