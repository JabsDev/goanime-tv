import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goanime_tv/core/anilist/anilist_pairing_server.dart';

/// Verifies the AniList LAN pairing server boots and serves the pairing pages
/// and the /token endpoint (rejecting an invalid token without a token typed).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Pairing server serves pages + rejects bad token',
      (tester) async {
    final server = AniListPairingServer();
    final ok = await server.start();
    debugPrint('pairing started=$ok url=${server.pairUrl}');
    expect(ok, true, reason: 'server should start on LAN');
    expect(server.pairUrl != null, true);

    final base = server.pairUrl!; // http://ip:port/
    final client = HttpClient();

    Future<String> get(String path) async {
      final req = await client.getUrl(Uri.parse('$base$path'));
      final res = await req.close();
      return res.transform(const SystemEncoding().decoder).join();
    }

    final landing = await get('');
    debugPrint('landing has AniList link: ${landing.contains('Entrar com AniList')}');
    expect(landing.contains('authorize'), true);
    expect(landing.contains('redirect_uri'), true);

    final callback = await get('callback');
    expect(callback.contains('access_token'), true,
        reason: 'callback page must read the token fragment');

    // POST an invalid token -> should be rejected (400) and not complete login.
    final req = await client.postUrl(Uri.parse('${base}token'));
    req.write('not-a-real-token');
    final res = await req.close();
    debugPrint('token endpoint status=${res.statusCode}');
    expect(res.statusCode, 400);

    client.close(force: true);
    await server.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));
}
