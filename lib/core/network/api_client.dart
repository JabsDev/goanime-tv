import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../cache/app_caches.dart';
import '../constants/app_constants.dart';

/// Thin wrapper around [http] that transparently caches GET responses (by URL
/// + headers) for the current session. This dedupes identical page/API fetches
/// performed by the different scrapers (e.g. the same AllAnime query or the
/// same image page) without touching the network again.
class ApiClient {
  const ApiClient();

  /// Test hooks: swap in a mock [http.Client] and zero the rate-limit backoff
  /// so 429-retry tests run fast without real network or sleeps.
  static http.Client? clientOverride;
  static Duration rateLimitBaseDelay = const Duration(milliseconds: 800);

  Future<http.Response> _get(
      Uri uri, Map<String, String>? headers, Duration? timeout) async {
    final client = clientOverride ?? http.Client();
    try {
      return await client
          .get(uri, headers: headers)
          .timeout(timeout ?? AppConstants.requestTimeout);
    } finally {
      if (clientOverride == null) client.close();
    }
  }

  /// Executes a function with retry logic using exponential backoff.
  static Future<T> _retryWithBackoff<T>(
    Future<T> Function() operation, {
    int maxRetries = 3,
    int initialDelay = 500,
    int maxDelay = 5000,
    bool retryOnTimeout = true,
    bool retryOnError = false,
    bool Function(Exception)? shouldRetry,
  }) async {
    var attempt = 0;
    var currentDelay = initialDelay;
    var maxDelayVal = maxDelay;

    while (true) {
      try {
        return await operation();
      } on TimeoutException catch (e) {
        if (attempt >= maxRetries) {
          rethrow;
        }
        if (!retryOnTimeout) {
          rethrow;
        }
        if (shouldRetry != null && !shouldRetry(e)) {
          rethrow;
        }
        attempt++;
        await Future.delayed(Duration(milliseconds: currentDelay));
        currentDelay = currentDelay * 2 < maxDelayVal ? currentDelay * 2 : maxDelayVal;
      } on Exception catch (e) {
        if (attempt >= maxRetries) {
          rethrow;
        }
        if (!retryOnError) {
          rethrow;
        }
        if (shouldRetry != null && !shouldRetry(e)) {
          rethrow;
        }
        attempt++;
        await Future.delayed(Duration(milliseconds: currentDelay));
        currentDelay = currentDelay * 2 < maxDelayVal ? currentDelay * 2 : maxDelayVal;
      }
    }
  }

  Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
    int maxRetries = 3,
    bool retryOnTimeout = true,
  }) async {
    final key = 'GET:${uri.toString()}:${headers?.toString() ?? ''}';
    
    // Try cache first. Only 200/301 bodies are ever stored (see
    // setWithErrorHandling), so reconstruct with an explicit UTF-8 charset:
    // without the header, `http.Response` re-encodes the body as Latin-1 and
    // crashes on non-Latin1 characters (accents, en-dashes) in cached pages.
    final cached = AppCaches.get(key);
    if (cached != null) {
      return http.Response(
        utf8.decode(cached),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }

    final res = await _retryWithBackoff(
      () => _get(uri, headers, timeout),
      maxRetries: maxRetries,
      retryOnTimeout: retryOnTimeout,
      retryOnError: true,
    );

    // Fase C: HTTP 429 (rate limiting) comes back as a normal response, not an
    // exception, so the backoff helper above can't catch it. Retry with a
    // growing wait + jitter instead of surfacing it.
    var response = res;
    var wait = rateLimitBaseDelay.inMilliseconds;
    for (var attempt = 0;
        attempt < maxRetries && response.statusCode == 429;
        attempt++) {
      await Future.delayed(Duration(
          milliseconds:
              wait + (rateLimitBaseDelay == Duration.zero ? 0 : Random().nextInt(200))));
      response = await _retryWithBackoff(
        () => _get(uri, headers, timeout),
        maxRetries: maxRetries,
        retryOnTimeout: retryOnTimeout,
        retryOnError: true,
      );
      wait *= 2;
    }

    // Don't cache error responses
    if (response.statusCode == 200) {
      AppCaches.setWithErrorHandling(key, response.bodyBytes, response.statusCode);
    }
    
    return response;
  }

  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
    int maxRetries = 3,
    bool retryOnTimeout = true,
  }) async {
    return _retryWithBackoff(
      () => http.post(uri, headers: headers, body: body).timeout(timeout ?? AppConstants.requestTimeout),
      maxRetries: maxRetries,
      retryOnTimeout: retryOnTimeout,
      retryOnError: true,
    );
  }

  Future<http.Response> postJson(
    Uri uri, {
    required Map<String, dynamic> json,
    Map<String, String>? headers,
    Duration? timeout,
    int maxRetries = 3,
    bool retryOnTimeout = true,
  }) async {
    final merged = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      ...?headers,
    };
    return post(
      uri,
      headers: merged,
      body: jsonEncode(json),
      timeout: timeout,
      maxRetries: maxRetries,
      retryOnTimeout: retryOnTimeout,
    );
  }
}

const apiClient = ApiClient();
