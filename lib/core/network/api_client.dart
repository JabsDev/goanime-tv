import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../cache/app_caches.dart';
import '../constants/app_constants.dart';

/// Thin wrapper around [http] that transparently caches GET responses (by URL
/// + headers) for the current session. This dedupes identical page/API fetches
/// performed by the different scrapers (e.g. the same AllAnime query or the
/// same image page) without touching the network again.
class ApiClient {
  const ApiClient();

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
    
    // Try cache first
    final cached = AppCaches.get(key);
    if (cached != null) {
      // Check if cache is an error response
      final cachedBody = String.fromCharCodes(cached);
      if (cachedBody.contains('403') || cachedBody.contains('404')) {
        AppCaches.clear(key);
      } else {
        return http.Response(utf8.decode(cached), 200);
      }
    }

    final res = await _retryWithBackoff(
      () => http.get(uri, headers: headers).timeout(timeout ?? AppConstants.requestTimeout),
      maxRetries: maxRetries,
      retryOnTimeout: retryOnTimeout,
      retryOnError: true,
    );

    // Don't cache error responses
    if (res.statusCode == 200) {
      AppCaches.setWithErrorHandling(key, res.bodyBytes, res.statusCode);
    }
    
    return res;
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
