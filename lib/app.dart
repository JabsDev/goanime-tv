import 'package:flutter/material.dart';
import 'features/home/home_screen.dart';
import 'shared/theme/app_theme.dart';

class GoAnimeTVApp extends StatelessWidget {
  const GoAnimeTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoAnime TV',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const HomeScreen(),
    );
  }
}
