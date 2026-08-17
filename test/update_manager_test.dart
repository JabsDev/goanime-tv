import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/updater/update_service.dart';
import 'package:goanime_tv/features/updater/update_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Serve uma release instalável em /releases/latest e 404 no resto.
  MockClient releaseClient() {
    return MockClient((req) async {
      if (req.url.path.endsWith('/releases/latest')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'tag_name': 'v1.0.1+1000001',
            'name': 'v1.0.1+1000001',
            'body': 'changelog',
            'prerelease': false,
            'draft': false,
            'assets': [
              {
                'name': 'a.apk',
                'size': 1,
                'browser_download_url': 'https://x/a.apk',
              },
            ],
          })),
          200,
        );
      }
      return http.Response('', 404);
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.instance.debugReset();
    await UpdateService.instance.init();
    UpdateService.instance.debugSetInstalled(build: 1000000, version: '1.0.0');
  });

  tearDown(() {
    UpdateService.clientOverride = null;
    UpdateService.instance.debugReset();
  });

  testWidgets('race do whenComplete não duplica o flow dialog', (tester) async {
    UpdateService.clientOverride = releaseClient();

    await tester.pumpWidget(MaterialApp(
      home: UpdateManager(child: const Scaffold(body: Text('root'))),
    ));
    await tester.pump(); // post-frame → check automático dispara
    await tester.pumpAndSettle(); // updateAvailable → diálogo available
    expect(find.byType(Dialog), findsOneWidget);

    // "Atualizar agora" → downloading (pop available + abre flow). O download
    // falha rápido sem PathProvider → estado error. Sem o fix, o whenComplete
    // do available rodaria em microtask e zeraria _openDialog, duplicando o
    // diálogo na transição seguinte.
    await tester.tap(find.text('Atualizar agora'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget); // AINDA 1 — sem duplicata

    // Stress: transições manuais não podem reabrir o flow dialog (guard 'flow').
    // Nota: `downloading`/`installing` renderizam LinearProgressIndicator
    // indeterminado (anima para sempre) → usar `pump()` fixo, não pumpAndSettle.
    for (final st in [
      UpdateState.downloading,
      UpdateState.installing,
      UpdateState.done,
    ]) {
      UpdateService.instance.debugSetState(st);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(Dialog), findsOneWidget);
    }
  });

  testWidgets('done: Fechar fecha o diálogo via _sync (dismiss→idle→pop)',
      (tester) async {
    UpdateService.clientOverride = releaseClient();

    await tester.pumpWidget(MaterialApp(
      home: UpdateManager(child: const Scaffold(body: Text('root'))),
    ));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget); // available

    UpdateService.instance.debugSetState(UpdateState.done);
    // O _sync do UpdateManager roda em post-frame callback; fora de frame a
    // árvore fica ociosa e nada agenda frame → agendamos explicitamente.
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget); // flow (done)
    expect(find.text('Fechar'), findsOneWidget);

    await tester.tap(find.text('Fechar'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(UpdateService.instance.state.value, UpdateState.idle);
  });
}
