import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/data/models/anilist_models.dart';

dynamic _cast(dynamic v) =>
    v is Map ? v.map((k, val) => MapEntry(k.toString(), _cast(val))) : v;

Map<String, dynamic> _m(Map<String, dynamic> src) =>
    src.map((k, v) => MapEntry(k, _cast(v)));

void main() {
  test('parses nextAiringEpisode so a RELEASING series can build a grid', () {
    final detail = AniListMediaDetail.fromJson(_m({
      'id': 21,
      'episodes': null,
      'status': 'RELEASING',
      'nextAiringEpisode': {'episode': 1173, 'timeUntilAiring': 203320},
      'title': {'english': 'One Piece'},
      'coverImage': <String, dynamic>{},
    }));
    expect(detail.episodes, isNull);
    expect(detail.nextAiringEpisodeNumber, 1173);
  });

  test('nextAiringEpisode is null when absent', () {
    final detail = AniListMediaDetail.fromJson(_m({
      'id': 1,
      'episodes': 24,
      'status': 'FINISHED',
      'title': {'english': 'X'},
      'coverImage': <String, dynamic>{},
    }));
    expect(detail.nextAiringEpisodeNumber, isNull);
  });
}