import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/sources/anime_fire_adapter.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';

class MockHttpClient extends Mock implements http.Client {}

String loadFixture(String path) => File(path).readAsStringSync();

void main() {
  late String fixtureHtml;

  setUpAll(() {
    fixtureHtml = loadFixture('test/fixtures/anime_fire/search_naruto.html');
    registerFallbackValue(Uri());
  });

  group('AnimeFireAdapter search with fixture', () {
    test('parses search results from fixture HTML', () async {
      final mockClient = MockHttpClient();
      when(() => mockClient.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response.bytes(utf8.encode(fixtureHtml), 200));

      final adapter = AnimeFireAdapter(client: mockClient);
      final result = await adapter.search('naruto');

      expect(result, isA<Success<List<Anime>>>());
      final data = (result as Success<List<Anime>>).data;
      expect(data.isNotEmpty, isTrue);
      expect(
        data.any((anime) => anime.name.toLowerCase().contains('naruto')),
        isTrue,
      );
      verify(() => mockClient.get(any(), headers: any(named: 'headers')))
          .called(1);
    });

    test('handles empty search results', () async {
      final mockClient = MockHttpClient();
      when(() => mockClient.get(any(), headers: any(named: 'headers')))
          .thenAnswer(
              (_) async => http.Response('<html><body>No results</body></html>', 200));

      final adapter = AnimeFireAdapter(client: mockClient);
      final result = await adapter.search('zzzznonexistent');

      expect(result, isA<Failure<List<Anime>>>());
      expect((result as Failure<List<Anime>>).error, isA<EmptyResultError>());
    });

    test('returns Failure for non-200 response', () async {
      final mockClient = MockHttpClient();
      when(() => mockClient.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async => http.Response('Not Found', 404));

      final adapter = AnimeFireAdapter(client: mockClient);
      final result = await adapter.search('naruto');

      expect(result, isA<Failure<List<Anime>>>());
    });

    test('retries on TimeoutException', () async {
      final mockClient = MockHttpClient();
      var callCount = 0;
      when(() => mockClient.get(any(), headers: any(named: 'headers')))
          .thenAnswer((_) async {
        callCount++;
        if (callCount == 1) throw TimeoutException('timed out');
        return http.Response.bytes(utf8.encode(fixtureHtml), 200);
      });

      final adapter = AnimeFireAdapter(client: mockClient);
      final result = await adapter.search('naruto');

      expect(result, isA<Success<List<Anime>>>());
      verify(() => mockClient.get(any(), headers: any(named: 'headers')))
          .called(2);
    });

    test('returns Failure on second timeout', () async {
      final mockClient = MockHttpClient();
      when(() => mockClient.get(any(), headers: any(named: 'headers')))
          .thenThrow(TimeoutException('timed out'));

      final adapter = AnimeFireAdapter(client: mockClient);
      final result = await adapter.search('naruto');

      expect(result, isA<Failure<List<Anime>>>());
      final failure = result as Failure<List<Anime>>;
      expect(failure.error, isA<TimeoutError>());
    });
  });
}
