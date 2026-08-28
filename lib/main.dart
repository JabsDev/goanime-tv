import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'core/profile/profile_service.dart';
import 'core/storage/local_storage.dart';
import 'core/storage/settings_service.dart';
import 'core/updater/update_service.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ponytail: esconde botões de navegação do Android durante todo o uso do app
  // (immersive sticky: reaparecem temporariamente com swipe, depois somem).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // ponytail: cap explícito do imageCache. Default Flutter é 1000 imagens / 100MB;
  // em TV stick 1GB heap estoura. 60MB/250 é conservador para qualquer hardware.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 60 << 20;
  PaintingBinding.instance.imageCache.maximumSize = 250;
  try {
    MediaKit.ensureInitialized();
    await LocalStorage.init();
    await SettingsService.instance.init();
    await ProfileService.instance.init();
    await UpdateService.instance.init();
    runApp(const GoAnimeTVApp());
  } catch (e) {
    debugPrint('[Main] Error initializing app: $e');
    runApp(
      MaterialApp(
        title: 'GoAnime TV - Error',
        home: Scaffold(
          backgroundColor: Color(0xFF0A0A0F),
          body: Center(
            child: Text(
              'Erro ao carregar o aplicativo. Verifique as configurações.',
              style: TextStyle(color: Colors.white, fontSize: 18),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
