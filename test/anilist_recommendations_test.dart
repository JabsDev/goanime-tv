import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/core/cache/app_caches.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppCaches.clearAll();
    SharedPreferences.setMockInitialValues({});
    AniListService.lastErrorStatus = AniListStatus.ok;
    AniListService.anilistRequestGap = const Duration(milliseconds: 2);
  });

  tearDown(() {
    AniListService.httpOverride = null;
    AniListService.anilistRequestGap = const Duration(milliseconds: 800);
  });

  Map<String, dynamic> media(int id, String romaji, String type,
          {bool isAdult = false}) =>
      {
        'id': id,
        'idMal': id * 10,
        'duration': 24,
        'type': type,
        'isAdult': isAdult,
        'title': {'romaji': romaji, 'english': null, 'native': null},
        'coverImage': {
          'extraLarge': 'http://img/$id',
          'large': null,
          'medium': null,
        },
        'bannerImage': null,
        'description': 'desc $id',
        'episodes': 12,
        'status': 'FINISHED',
        'averageScore': 80,
        'genres': ['Action'],
      };

  test('getRecommendations devolve só ANIME, deduplicado', () async {
    late Map<String, dynamic> requestBody;
    AniListService.httpOverride = MockClient((req) async {
      requestBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'data': {
            'Media': {
              'recommendations': {
                'nodes': [
                  {'rating': 50, 'mediaRecommendation': media(1, 'Shingeki no Kyojin', 'ANIME')},
                  {'rating': 40, 'mediaRecommendation': media(2, 'Manga X', 'MANGA')},
                  {'rating': 30, 'mediaRecommendation': media(1, 'Shingeki no Kyojin', 'ANIME')},
                  {'rating': 20, 'mediaRecommendation': null},
                  {
                    'rating': 10,
                    'mediaRecommendation':
                        media(3, 'Steins;Gate', 'ANIME', isAdult: true),
                  },
                ],
              },
            },
          },
        })),
        200,
      );
    });

    final recs = await AniListService.getRecommendations(42);

    expect((requestBody['query'] as String), contains('recommendations'));
    expect(requestBody['variables']['mediaId'], 42);
    expect(recs.map((a) => a.name), ['Shingeki no Kyojin', 'Steins;Gate']);
    expect(recs.map((a) => a.anilistId), [1, 3]);
    expect(recs.first.imageUrl, 'http://img/1');
    expect(recs.last.isAdult, isTrue);
    expect(AniListService.lastErrorStatus, AniListStatus.ok);
  });

  test('getRecommendations cacheia: segunda chamada não vai à rede', () async {
    var calls = 0;
    AniListService.httpOverride = MockClient((req) async {
      calls++;
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'data': {
            'Media': {
              'recommendations': {
                'nodes': [
                  {'rating': 50, 'mediaRecommendation': media(7, 'Bleach', 'ANIME')},
                ],
              },
            },
          },
        })),
        200,
      );
    });

    final first = await AniListService.getRecommendations(7);
    final second = await AniListService.getRecommendations(7);

    expect(calls, 1);
    expect(first.map((a) => a.name), ['Bleach']);
    expect(second.map((a) => a.name), ['Bleach']);
  });

  test('getRecommendations erro 500 não lança e volta vazio', () async {
    AniListService.httpOverride = MockClient(
      (req) async => http.Response('erro', 500),
    );

    final recs = await AniListService.getRecommendations(99);

    expect(recs, isEmpty);
    expect(AniListService.lastErrorStatus, AniListStatus.serverError);
  });

  test('getRecommendations com mediaId inválido nem chama a rede', () async {
    var calls = 0;
    AniListService.httpOverride = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });

    expect(await AniListService.getRecommendations(0), isEmpty);
    expect(calls, 0);
  });
}
