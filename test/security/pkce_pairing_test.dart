import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:goanime_tv/core/anilist/anilist_pairing_server.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';

String anilistServiceSource() {
  return File('lib/core/anilist/anilist_service.dart').readAsStringSync();
}

void main() {
  late AniListPairingServer server;
  late Uri baseUri;

  setUp(() async {
    server = AniListPairingServer();
    final started = await server.start();
    if (!started) throw Exception('Server failed to start');
    baseUri = Uri.parse(server.pairUrl!);
  });

  tearDown(() => server.dispose());

  group('PKCE Authorization Flow', () {
    test('GET / returns landing page with PKCE params', () async {
      final res = await http.get(baseUri);
      expect(res.statusCode, equals(200));
      expect(res.body, contains('code_challenge_method=S256'));
      expect(res.body, contains('response_type=code'));
      expect(res.body, contains('state='));
      expect(res.body, contains('code_challenge='));
    });

    test('landing page authorize URL excludes client_secret', () async {
      final res = await http.get(baseUri);
      expect(res.body, isNot(contains('client_secret')));
    });

    test('landing page redirect URL includes client_id', () async {
      final res = await http.get(baseUri);
      expect(res.body, contains('client_id=44217'));
    });
  });

  group('CSRF Protection', () {
    test('landing page has CSRF meta tag', () async {
      final res = await http.get(baseUri);
      final match =
          RegExp(r'<meta name="csrf-token" content="([^"]*)"').firstMatch(res.body);
      expect(match, isNotNull);
      expect(match!.group(1)!.length, greaterThanOrEqualTo(32));
    });

    test('callback page JS includes csrf_token in POST body', () async {
      final res = await http.get(baseUri.replace(path: '/callback'));
      expect(res.body, contains('csrf_token'));
    });

    test('POST /token without csrf_token returns 403', () async {
      final res = await http.post(
        baseUri.replace(path: '/token'),
        body: 'access_token=test',
      );
      expect(res.statusCode, equals(403));
    });
  });

  group('Origin Validation', () {
    test('POST /token with wrong Origin returns 403', () async {
      final res = await http.post(
        baseUri.replace(path: '/token'),
        headers: {'Origin': 'http://evil.com'},
        body: 'code=test&state=test&csrf_token=test',
      );
      expect(res.statusCode, equals(403));
    });
  });

  group('Rate Limiting', () {
    test('6th POST /token from same IP within 60s returns 429', () async {
      final url = baseUri.replace(path: '/token');
      for (var i = 0; i < 5; i++) {
        await http.post(url, body: 'test_body_$i');
      }
      final res = await http.post(url, body: 'test_body_6th');
      expect(res.statusCode, equals(429));
    });
  });

  group('CORS', () {
    test('Access-Control-Allow-Origin is restricted', () async {
      final res = await http.get(baseUri);
      final corsHeader = res.headers['access-control-allow-origin'];
      expect(corsHeader, isNotNull);
      expect(corsHeader, isNot(equals('*')));
      expect(corsHeader, matches(r'^http://'));
    });
  });

  test('AniListService.exchangeCodeForToken exists', () {
    // Read source file to check method existence — avoids compile-time errors
    // when the method hasn't been implemented yet (RED phase).
    final source = anilistServiceSource();
    expect(source, contains('static Future<String?> exchangeCodeForToken('));
  });
}
