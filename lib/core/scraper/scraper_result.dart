import '../../data/models/anime.dart' show AnimeSource;

sealed class ScraperResult<T> {
  const ScraperResult();

  factory ScraperResult.success(T data) = Success<T>;

  factory ScraperResult.failure(ScraperError error) = Failure<T>;
}

final class Loading<T> extends ScraperResult<T> {
  const Loading();
}

final class Success<T> extends ScraperResult<T> {
  final T data;
  const Success(this.data);

  bool get isSuccess => true;
}

final class Failure<T> extends ScraperResult<T> {
  final ScraperError error;
  const Failure(this.error);

  bool get isSuccess => false;
}

sealed class ScraperError {
  final String message;
  final AnimeSource source;

  const ScraperError({
    required this.message,
    required this.source,
  });
}

final class TimeoutError extends ScraperError {
  const TimeoutError({
    required super.message,
    required super.source,
  });
}

final class ParseFailureError extends ScraperError {
  const ParseFailureError({
    required super.message,
    required super.source,
  });
}

final class CloudflareError extends ScraperError {
  final String detectionPattern;
  const CloudflareError({
    required super.message,
    required super.source,
    required this.detectionPattern,
  });
}

final class EmptyResultError extends ScraperError {
  const EmptyResultError({
    required super.message,
    required super.source,
  });
}

final class UnknownError extends ScraperError {
  const UnknownError({
    required super.message,
    required super.source,
    Object? originalError,
  });
}

/// Error type enumeration for fallback routing
enum ScraperErrorType {
  emptyResult,   // Anime não encontrado
  unknown,       // Erro desconhecido
  timeout,       // Timeout
  cloudflare,    // Cloudflare/WAF
}

/// Extended error with fallback error type
class FallbackScraperError extends ScraperError {
  final ScraperErrorType errorType;
  final Map<String, dynamic> context;

  const FallbackScraperError({
    required super.message,
    required super.source,
    required this.errorType,
    this.context = const {},
  });
}

bool isCloudflareChallenge(String html, Map<String, String> headers) {
  if (html.contains('Verificação')) return true;
  if (html.contains('cf-browser-verification')) return true;
  if (html.contains('cf-challenge')) return true;

  for (final key in headers.keys) {
    if (key.startsWith('CF-Ray') || key.startsWith('CF-Challenge')) {
      return true;
    }
  }

  return false;
}

/// Result record for scraping metrics
class SearchResult {
  final String animeName;
  final int duration;
  final List<ScraperAttempt> attempts;
  final bool success;
  final DateTime timestamp;

  const SearchResult({
    required this.animeName,
    required this.duration,
    required this.attempts,
    required this.success,
    required this.timestamp,
  });
}

/// Single scraping attempt record
class ScraperAttempt {
  final bool success;
  final AnimeSource source;

  const ScraperAttempt(this.success, this.source);
}
