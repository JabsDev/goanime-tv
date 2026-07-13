import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/data/models/anime.dart';

void main() {
  group('ScraperResult', () {
    test('Success holds data and matches pattern', () {
      final result = ScraperResult<int>.success(42);
      expect(result, isA<Success<int>>());
      switch (result) {
        case Success(data: final d):
          expect(d, 42);
        case Failure():
          fail('Should be Success');
        case Loading():
          fail('Should be Success');
      }
    });

    test('Failure holds error and matches pattern', () {
      final error = UnknownError(
        message: 'Something broke',
        source: AnimeSource.animeFire,
        operationDuration: Duration.zero,
      );
      final result = ScraperResult<int>.failure(error);
      expect(result, isA<Failure<int>>());
      switch (result) {
        case Success():
          fail('Should be Failure');
        case Failure(error: final e):
          expect(e.message, 'Something broke');
          expect(e.source, AnimeSource.animeFire);
        case Loading():
          fail('Should be Failure');
      }
    });

    test('Loading is distinct variant', () {
      const result = Loading<int>();
      expect(result, isA<Loading<int>>());
    });
  });

  group('ScraperError variants carry correct metadata', () {
    test('TimeoutError has timeoutValue', () {
      final error = TimeoutError(
        message: 'Timed out',
        source: AnimeSource.superFlix,
        operationDuration: const Duration(seconds: 5),
        timeoutValue: const Duration(seconds: 15),
      );
      expect(error.timeoutValue, const Duration(seconds: 15));
    });

    test('ParseFailureError has snippet', () {
      final error = ParseFailureError(
        message: 'Parse error',
        source: AnimeSource.animeFire,
        operationDuration: Duration.zero,
        snippet: '<div>broken',
      );
      expect(error.snippet, '<div>broken');
    });

    test('EmptyResultError carries message', () {
      final error = EmptyResultError(
        message: 'No results',
        source: AnimeSource.goyabu,
        operationDuration: Duration.zero,
      );
      expect(error.message, 'No results');
    });

    test('CloudflareError has detectionPattern', () {
      final error = CloudflareError(
        message: 'Cloudflare challenge',
        source: AnimeSource.superFlix,
        operationDuration: Duration.zero,
        detectionPattern: 'Verificação',
      );
      expect(error.detectionPattern, 'Verificação');
    });

    test('UnknownError has optional originalError', () {
      final withError = UnknownError(
        message: 'With error',
        source: AnimeSource.animeFire,
        operationDuration: Duration.zero,
        originalError: Exception('original cause'),
      );
      expect(withError.originalError, isNotNull);

      final withoutError = UnknownError(
        message: 'Without error',
        source: AnimeSource.animeFire,
        operationDuration: Duration.zero,
      );
      expect(withoutError.originalError, isNull);
    });
  });
}
