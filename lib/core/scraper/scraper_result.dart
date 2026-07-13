import '../../data/models/anime.dart' show AnimeSource;

/// Typed result from any scraper/adapter operation.
///
/// Replaces the blanket `catch (e) { return []; }` pattern with three
/// exhaustively matchable variants: [Loading], [Success], and [Failure].
sealed class ScraperResult<T> {
  const ScraperResult();
}

final class Loading<T> extends ScraperResult<T> {
  const Loading();
}

final class Success<T> extends ScraperResult<T> {
  final T data;
  const Success(this.data);
}

final class Failure<T> extends ScraperResult<T> {
  final ScraperError error;
  const Failure(this.error);
}

/// Typed error variants for scraper operations.
///
/// Every variant carries a human-readable [message], the [AnimeSource] that
/// produced the error, and timing information via [operationDuration].
sealed class ScraperError {
  final String message;
  final AnimeSource source;
  final Duration operationDuration;

  const ScraperError({
    required this.message,
    required this.source,
    required this.operationDuration,
  });
}

final class TimeoutError extends ScraperError {
  final Duration timeoutValue;
  const TimeoutError({
    required super.message,
    required super.source,
    required super.operationDuration,
    required this.timeoutValue,
  });
}

final class ParseFailureError extends ScraperError {
  final String snippet;
  const ParseFailureError({
    required super.message,
    required super.source,
    required super.operationDuration,
    required this.snippet,
  });
}

final class CloudflareError extends ScraperError {
  final String detectionPattern;
  const CloudflareError({
    required super.message,
    required super.source,
    required super.operationDuration,
    required this.detectionPattern,
  });
}

final class EmptyResultError extends ScraperError {
  const EmptyResultError({
    required super.message,
    required super.source,
    required super.operationDuration,
  });
}

final class UnknownError extends ScraperError {
  final Object? originalError;
  const UnknownError({
    required super.message,
    required super.source,
    required super.operationDuration,
    this.originalError,
  });
}

/// Multi-pattern Cloudflare challenge detection.
///
/// Checks for known Cloudflare challenge indicators in both HTML content and
/// response headers. The HTTP status code (403/503) should be checked by the
/// caller before invoking this function.
///
/// **Detection patterns:**
/// - Content: `Verificação`, `cf-browser-verification`, `cf-challenge`
/// - Headers: `CF-Ray`, `CF-Challenge` header keys
bool isCloudflareChallenge(String html, Map<String, String> headers) {
  // Content-based patterns
  if (html.contains('Verificação')) return true;
  if (html.contains('cf-browser-verification')) return true;
  if (html.contains('cf-challenge')) return true;

  // Header-based patterns
  for (final key in headers.keys) {
    if (key.startsWith('CF-Ray') || key.startsWith('CF-Challenge')) {
      return true;
    }
  }

  return false;
}
