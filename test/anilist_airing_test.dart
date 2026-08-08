import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/core/cache/app_caches.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppCaches.clearAll();
    AniListService.lastErrorStatus = AniListStatus.ok;
    AniListService.anilistRequestGap = const Duration(milliseconds: 2);
  });

  tearDown(() {
    AniListService.httpOverride = null;
    AniListService.anilistRequestGap = const Duration(milliseconds: 800);
  });

  String schedule(Map<String, dynamic> media, {int episode = 5}) => '''
    {
      "id": ${media['id']! * 100 + episode},
      "episode": $episode,
      "airingAt": 1000000,
      "media": ${jsonEncode(media)}
    }
  ''';

  Map<String, dynamic> media(int id, String romaji) => {
        'id': id,
        'title': {'romaji': romaji, 'english': null, 'native': null},
        'coverImage': {'extraLarge': null, 'large': 'http://img/$id', 'medium': null},
      };

  test('getAiringTomorrow retorna animes deduplicados do AiringSchedule', () async {
    AniListService.httpOverride = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['variables']['airingAt_greater'], isNotNull);
      expect(body['variables']['airingAt_lesser'], isNotNull);
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'data': {
            'Page': {
              'airingSchedules': [
                jsonDecode(schedule(media(1, 'Naruto'), episode: 5)),
                jsonDecode(schedule(media(1, 'Naruto'), episode: 6)),
                jsonDecode(schedule(media(2, 'One Piece'), episode: 1200)),
              ],
            },
          },
        })),
        200,
      );
    });

    final animes = await AniListService.getAiringTomorrow();
    expect(animes.length, 2); // Naruto deduplicado (2 eps) + One Piece
    expect(animes.map((a) => a.name), contains('Naruto'));
    expect(animes.map((a) => a.name), contains('One Piece'));
    expect(animes.first.imageUrl, 'http://img/1'); // cover vindo do schedule
    expect(AniListService.lastErrorStatus, AniListStatus.ok);
  });

  test('getAiringTomorrow erro 500 não lança e volta vazio', () async {
    AniListService.httpOverride = MockClient(
      (req) async => http.Response('erro', 500),
    );
    final result = await AniListService.getAiringTomorrow();
    expect(result, isEmpty);
    expect(AniListService.lastErrorStatus, AniListStatus.serverError);
  });
}