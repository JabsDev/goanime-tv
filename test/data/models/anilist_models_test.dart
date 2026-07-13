import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/data/models/anilist_models.dart';

Map<String, dynamic> _fullJson() {
  return {
    'id': 16498,
    'bannerImage': 'https://example.com/banner.jpg',
    'description': 'A test anime description.',
    'episodes': 500,
    'status': 'FINISHED',
    'averageScore': 80.0,
    'genres': ['Action', 'Adventure', 'Fantasy'],
    'coverImage': {
      'extraLarge': 'https://example.com/extra_large.jpg',
      'large': 'https://example.com/large.jpg',
      'medium': 'https://example.com/medium.jpg',
    },
  };
}

void main() {
  group('AniListMediaDetail.fromJson', () {
    test('parses full response correctly', () {
      final detail = AniListMediaDetail.fromJson(_fullJson());

      expect(detail.id, equals(16498));
      expect(detail.bannerImage, equals('https://example.com/banner.jpg'));
      expect(detail.description, equals('A test anime description.'));
      expect(detail.episodes, equals(500));
      expect(detail.status, equals('FINISHED'));
      expect(detail.averageScore, equals(80.0));
      expect(detail.genres, containsAll(['Action', 'Adventure', 'Fantasy']));
      expect(detail.coverImage.best, equals('https://example.com/extra_large.jpg'));
      expect(detail.coverImage.large, equals('https://example.com/large.jpg'));
      expect(detail.coverImage.medium, equals('https://example.com/medium.jpg'));
      expect(detail.coverImage.extraLarge, equals('https://example.com/extra_large.jpg'));
    });

    test('handles null/empty fields gracefully', () {
      final detail = AniListMediaDetail.fromJson({});

      expect(detail.id, equals(0));
      expect(detail.bannerImage, isNull);
      expect(detail.description, isNull);
      expect(detail.episodes, isNull);
      expect(detail.status, isNull);
      expect(detail.averageScore, isNull);
      expect(detail.genres, isEmpty);
      expect(detail.coverImage.best, equals(''));
    });

    test('handles missing coverImage', () {
      final json = <String, dynamic>{
        'id': 1,
      };
      final detail = AniListMediaDetail.fromJson(json);

      expect(detail.coverImage.best, equals(''));
    });

    test('handles averageScore as int (converts to double)', () {
      final json = <String, dynamic>{
        'id': 1,
        'averageScore': 75,
        'coverImage': <String, dynamic>{},
      };
      final detail = AniListMediaDetail.fromJson(json);

      expect(detail.averageScore, equals(75.0));
    });

    test('handles averageScore as double', () {
      final json = <String, dynamic>{
        'id': 1,
        'averageScore': 75.5,
        'coverImage': <String, dynamic>{},
      };
      final detail = AniListMediaDetail.fromJson(json);

      expect(detail.averageScore, equals(75.5));
    });

    test('handles null averageScore', () {
      final json = <String, dynamic>{
        'id': 1,
        'averageScore': null,
        'coverImage': <String, dynamic>{},
      };
      final detail = AniListMediaDetail.fromJson(json);

      expect(detail.averageScore, isNull);
    });
  });

  group('AniListCoverImage.fromJson', () {
    test('parses extraLarge as best when available', () {
      final image = AniListCoverImage.fromJson({
        'extraLarge': 'https://example.com/extra_large.jpg',
        'large': 'https://example.com/large.jpg',
        'medium': 'https://example.com/medium.jpg',
      });

      expect(image.best, equals('https://example.com/extra_large.jpg'));
      expect(image.large, equals('https://example.com/large.jpg'));
      expect(image.medium, equals('https://example.com/medium.jpg'));
      expect(image.extraLarge, equals('https://example.com/extra_large.jpg'));
    });

    test('falls back to large when extraLarge missing', () {
      final image = AniListCoverImage.fromJson({
        'large': 'https://example.com/large.jpg',
        'medium': 'https://example.com/medium.jpg',
      });

      expect(image.best, equals('https://example.com/large.jpg'));
    });

    test('falls back to medium when only medium available', () {
      final image = AniListCoverImage.fromJson({
        'medium': 'https://example.com/medium.jpg',
      });

      expect(image.best, equals('https://example.com/medium.jpg'));
    });

    test('returns empty string when no images', () {
      final image = AniListCoverImage.fromJson({});

      expect(image.best, equals(''));
    });
  });

  group('AniListGraphQLResponse.fromJson', () {
    test('parses valid GraphQL response with nested Media', () {
      final json = <String, dynamic>{
        'data': {
          'Media': _fullJson(),
        },
      };
      final response = AniListGraphQLResponse.fromJson(json);

      expect(response.data.media.id, equals(16498));
      expect(response.data.media.episodes, equals(500));
    });

    test('handles missing data field', () {
      final response = AniListGraphQLResponse.fromJson({});

      expect(response.data.media.id, equals(0));
    });

    test('handles null Media field', () {
      final json = <String, dynamic>{
        'data': <String, dynamic>{},
      };
      final response = AniListGraphQLResponse.fromJson(json);

      expect(response.data.media.id, equals(0));
    });
  });
}
