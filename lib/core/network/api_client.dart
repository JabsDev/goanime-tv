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

  Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final key = 'GET:${uri.toString()}:${headers?.toString() ?? ''}';
    final cached = AppCaches.httpResponses.get<List<int>>(key);
    if (cached != null) {
      return http.Response.bytes(
        cached,
        200,
        request: http.Request('GET', uri),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }

    final res = await http
        .get(uri, headers: headers)
        .timeout(timeout ?? AppConstants.requestTimeout);

    if (res.statusCode == 200) {
      AppCaches.httpResponses.set<List<int>>(key, res.bodyBytes);
    }
    return res;
  }

  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    return http
        .post(uri, headers: headers, body: body)
        .timeout(timeout ?? AppConstants.requestTimeout);
  }

  Future<http.Response> postJson(
    Uri uri, {
    required Map<String, dynamic> json,
    Map<String, String>? headers,
    Duration? timeout,
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
    );
  }
}

const apiClient = ApiClient();
