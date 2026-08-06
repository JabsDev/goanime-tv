import 'package:flutter/material.dart';
import 'core/navigation/route_observer.dart';
import 'core/profile/profile_service.dart';
import 'features/home/home_screen.dart';
import 'features/profiles/profile_switcher_screen.dart';
import 'shared/theme/app_theme.dart';

class GoAnimeTVApp extends StatelessWidget {
  const GoAnimeTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    final profiles = ProfileService.instance.profiles;
    return MaterialApp(
      title: 'GoAnime TV',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      navigatorObservers: [routeObserver],
      home: profiles.length > 1
          ? const ProfileSwitcherScreen(showOnBoot: true)
          : const HomeScreen(),
    );
  }
}
