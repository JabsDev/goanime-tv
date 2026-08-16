import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/profile/profile_service.dart';
import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/features/home/home_screen.dart';
import 'package:goanime_tv/features/profiles/profile_switcher_screen.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String docs;
  _FakePathProvider(this.docs);
  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
  @override
  Future<String?> getTemporaryPath() async => '$docs/tmp';
  @override
  Future<String?> getApplicationSupportPath() async => '$docs/support';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('profile_switcher_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    await LocalStorage.init();
    await SettingsService.instance.init();
    await ProfileService.instance.init();
    ProfileService.instance.profiles.clear();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<void> pumpTv(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: child));
  }

  testWidgets(
      'primeira execução mostra boas-vindas e Visitante navega para a Home',
      (tester) async {
    expect(ProfileService.instance.profiles, isEmpty);
    expect(SettingsService.instance.onboardingSeen, isFalse);

    await pumpTv(
        tester, const ProfileSwitcherScreen(showOnBoot: true));
    expect(find.text('Bem-vindo ao GoAnime TV'), findsOneWidget);
    expect(find.text('Continuar como Visitante'), findsOneWidget);

    await tester.tap(find.text('Continuar como Visitante'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(SettingsService.instance.onboardingSeen, isTrue);
  });

  testWidgets('criar perfil local a partir das boas-vindas entra na Home',
      (tester) async {
    await pumpTv(
        tester, const ProfileSwitcherScreen(showOnBoot: true));
    await tester.tap(find.text('Adicionar perfil'));
    await tester.pumpAndSettle();
    expect(find.text('Adicionar conta'), findsOneWidget);

    await tester.tap(find.text('Conta local'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Família');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Criar'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(ProfileService.instance.profiles.map((p) => p.displayName),
        contains('Família'));
  });
}