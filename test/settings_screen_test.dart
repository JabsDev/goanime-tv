import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/updater/update_service.dart';
import 'package:goanime_tv/features/settings/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Response okList(Object body) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Map<String, dynamic> docsOnly(String tag) => {
        'tag_name': tag,
        'name': tag,
        'body': 'changelog',
        'prerelease': false,
        'draft': false,
        'assets': <Map<String, dynamic>>[],
      };

  Map<String, dynamic> releaseJson(String tag) => {
        'tag_name': tag,
        'name': tag,
        'body': 'changelog',
        'prerelease': false,
        'draft': false,
        'assets': [
          {
            'name': 'goanime-tv-$tag.apk',
            'size': 42,
            'browser_download_url': 'http://localhost:9999/goanime.apk',
          },
        ],
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetInstalled(build: 1000000, version: '1.0.0');
  });

  tearDown(() {
    UpdateService.clientOverride = null;
    UpdateService.instance.debugReset();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pump();
    // Garante que a row "Verificar agora" está dentro da viewport/construída.
    await tester.scrollUntilVisible(
      find.text('Verificar agora'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Verificar agora durante checking mostra feedback', (tester) async {
    UpdateService.instance.debugSetState(UpdateState.checking);
    await pumpSettings(tester);

    await tester.tap(find.text('Verificar agora'));
    await tester.pumpAndSettle();
    expect(find.text('Verificação em andamento...'), findsOneWidget);
    // Expira o timer do SnackBar para não deixar timer pendente.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('Verificar agora durante downloading mostra feedback',
      (tester) async {
    UpdateService.instance.debugSetState(UpdateState.downloading);
    await pumpSettings(tester);

    await tester.tap(find.text('Verificar agora'));
    await tester.pumpAndSettle();
    expect(find.text('Uma atualização está sendo baixada.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('docs-only mais nova → snackbar de indisponível (não "mais recente")',
      (tester) async {
    UpdateService.clientOverride = MockClient((req) async {
      if (req.url.path.endsWith('/releases/latest')) {
        return okList(docsOnly('v1.0.1+1000001'));
      }
      return okList([
        docsOnly('v1.0.1+1000001'),
        releaseJson('v1.0.0+1000000'),
      ]);
    });
    await pumpSettings(tester);

    await tester.tap(find.text('Verificar agora'));
    await tester.pumpAndSettle();
    expect(
      find.text('Existe uma versão nova, mas ela ainda não está disponível '
          'para instalação. Tente novamente mais tarde.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('erro de rede → snackbar de não foi possível verificar',
      (tester) async {
    UpdateService.clientOverride =
        MockClient((req) async => http.Response('rate limited', 429));
    await pumpSettings(tester);

    await tester.tap(find.text('Verificar agora'));
    await tester.pumpAndSettle();
    expect(find.text('Não foi possível verificar atualizações agora. Tente novamente.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
