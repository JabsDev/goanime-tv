import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'core/storage/local_storage.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    MediaKit.ensureInitialized();
    await LocalStorage.init();
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
