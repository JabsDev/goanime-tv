import 'package:flutter/material.dart';
import 'core/navigation/route_observer.dart';
import 'core/profile/profile_service.dart';
import 'core/storage/settings_service.dart';
import 'features/home/home_screen.dart';
import 'features/profiles/profile_switcher_screen.dart';
import 'features/updater/update_manager.dart';
import 'shared/theme/app_theme.dart';

class GoAnimeTVApp extends StatelessWidget {
  const GoAnimeTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    final profiles = ProfileService.instance.profiles;
    // Primeira execução (sem perfil e onboarding ainda não visto): oferece criar
    // um perfil local ou continuar como Visitante. Só depois cai milha home.
    final firstRun = profiles.isEmpty && !SettingsService.instance.onboardingSeen;
    return MaterialApp(
      title: 'GoAnime TV',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      navigatorObservers: [routeObserver],
      home: UpdateManager(
        child: firstRun || profiles.length > 1
            ? const ProfileSwitcherScreen(showOnBoot: true)
            : const HomeScreen(),
      ),
    );
  }
}