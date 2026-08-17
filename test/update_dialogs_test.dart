import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/updater/github_release_api.dart';
import 'package:goanime_tv/core/updater/update_service.dart';
import 'package:goanime_tv/features/updater/update_available_dialog.dart';
import 'package:goanime_tv/features/updater/update_flow_dialog.dart';
import 'package:goanime_tv/shared/widgets/tv_button.dart';

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

  testWidgets('UpdateAvailableDialog: autofocus cai no botão primário',
      (tester) async {
    await tester.pumpWidget(wrap(UpdateAvailableDialog(
      release: release,
      onUpdate: () {},
      onLater: () {},
      onIgnore: () {},
    )));
    await tester.pump(); // autofocus se aplica no 1º frame

    // O foco primário cai no Focus do TVButton "Atualizar agora" (autofocus
    // true). `Focus.of(texto)` não resolve (devolve o nó do scope), então
    // verifica por ancestralidade: o widget do nó em foco está sob o botão.
    final primary = tester.binding.focusManager.primaryFocus;
    expect(primary, isNotNull);
    final primaryWidget = primary!.context?.widget;
    expect(
      find
          .ancestor(
            of: find.text('Atualizar agora'),
            matching: find.byType(Focus),
          )
          .evaluate()
          .any((e) => e.widget == primaryWidget),
      isTrue,
    );
    // "Agora não" NÃO tem autofocus (default false):
    final tvButton = tester.widget<TVButton>(find.ancestor(
      of: find.text('Agora não'),
      matching: find.byType(TVButton),
    ));
    expect(tvButton.autofocus, isFalse);
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

  testWidgets('UpdateFlowDialog downloading: Cancelar tem autofocus',
      (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.downloading);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();

    final primary = tester.binding.focusManager.primaryFocus;
    expect(primary, isNotNull);
    expect(
      find
          .ancestor(
            of: find.text('Cancelar'),
            matching: find.byType(Focus),
          )
          .evaluate()
          .any((e) => e.widget == primary!.context?.widget),
      isTrue,
    );
  });

  testWidgets('UpdateFlowDialog installing: mostra Instalando e Voltar ao app',
      (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.installing);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();

    expect(find.text('Instalando...'), findsOneWidget);
    expect(find.text('Voltar ao app'), findsOneWidget);
    // autofocus no botão de saída
    final primary = tester.binding.focusManager.primaryFocus;
    expect(primary, isNotNull);
    expect(
      find
          .ancestor(
            of: find.text('Voltar ao app'),
            matching: find.byType(Focus),
          )
          .evaluate()
          .any((e) => e.widget == primary!.context?.widget),
      isTrue,
    );
  });

  testWidgets('UpdateFlowDialog installing: Voltar ao app fecha o diálogo',
      (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.installing);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SizedBox.expand()),
    ));
    unawaited(showDialog<void>(
      context: tester.element(find.byType(Scaffold)),
      barrierDismissible: false,
      builder: (_) => const UpdateFlowDialog(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Voltar ao app'), findsOneWidget);
    await tester.tap(find.text('Voltar ao app'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // O "Voltar ao app" faz pop: o diálogo some, sem mudar o estado do serviço.
    expect(find.byType(UpdateFlowDialog), findsNothing);
    expect(UpdateService.instance.state.value, UpdateState.installing);
  });

  testWidgets('UpdateFlowDialog mostra erro com retry/fallback', (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.error);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();

    expect(find.text('Não foi possível atualizar'), findsOneWidget);
    expect(find.text('Fechar'), findsOneWidget);
  });

  testWidgets('UpdateFlowDialog done: Fechar volta ao idle', (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.done);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();
    await tester.tap(find.text('Fechar'));
    await tester.pump();
    expect(UpdateService.instance.state.value, UpdateState.idle);
  });

  testWidgets('UpdateFlowDialog error: Fechar volta ao idle', (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.error);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();
    await tester.tap(find.text('Fechar'));
    await tester.pump();
    expect(UpdateService.instance.state.value, UpdateState.idle);
  });

  testWidgets('UpdateFlowDialog error: exatamente um TVButton com autofocus',
      (tester) async {
    UpdateService.instance.debugReset();
    UpdateService.instance.debugSetState(UpdateState.error);
    await tester.pumpWidget(wrap(UpdateFlowDialog()));
    await tester.pump();

    final autofocused = tester
        .widgetList<TVButton>(find.byType(TVButton))
        .where((b) => b.autofocus)
        .length;
    expect(autofocused, 1);
  });
}
