import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/updater/github_release_api.dart';
import 'package:goanime_tv/core/updater/update_service.dart';
import 'package:goanime_tv/features/updater/update_available_dialog.dart';
import 'package:goanime_tv/features/updater/update_flow_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final release = ReleaseInfo(
    tagName: 'v1.0.1+1000001',
    versionLabel: 'v1.0.1+1000001',
    changelog: '- correção de bugs\n- melhorias',
    apkUrl: Uri.parse('https://example.com/a.apk'),
  );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  tearDown(() {
    UpdateService.instance.debugReset();
  });

  testWidgets('UpdateAvailableDialog mostra versão, changelog e dispara ações',
      (tester) async {
    var updated = false, later = false, ignored = false;
    await tester.pumpWidget(wrap(UpdateAvailableDialog(
      release: release,
      onUpdate: () => updated = true,
      onLater: () => later = true,
      onIgnore: () => ignored = true,
    )));

    expect(find.textContaining('Nova versão 1.0.1'), findsOneWidget);
    expect(find.textContaining('correção de bugs'), findsOneWidget);
    expect(find.text('Atualizar agora'), findsOneWidget);

    await tester.tap(find.text('Atualizar agora'));
    expect(updated, isTrue);

    await tester.pumpWidget(wrap(UpdateAvailableDialog(
      release: release,
      onUpdate: () {},
      onLater: () => later = true,
      onIgnore: () => ignored = true,
    )));
    await tester.tap(find.text('Agora não'));
    expect(later, isTrue);

    await tester.pumpWidget(wrap(UpdateAvailableDialog(
      release: release,
      onUpdate: () {},
      onLater: () {},
      onIgnore: () => ignored = true,
    )));
    await tester.tap(find.text('Ignorar esta versão'));
    expect(ignored, isTrue);
  });

  testWidgets('UpdateFlowDialog reage ao estado downloading (com %)',
      (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.downloading);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();

    expect(find.text('Baixando atualização'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    // progresso indeterminado sem content-length
    expect(find.text('Conectando...'), findsOneWidget);
  });

  testWidgets('UpdateFlowDialog mostra erro com retry/fallback', (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.error);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();

    expect(find.text('Não foi possível atualizar'), findsOneWidget);
    expect(find.text('Fechar'), findsOneWidget);
  });
}