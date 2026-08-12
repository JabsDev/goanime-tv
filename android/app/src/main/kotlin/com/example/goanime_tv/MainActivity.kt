package com.example.goanime_tv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Registro único (singleTop nunca recria a Activity): o canal do
        // update e o receiver de resultado vivem enquanto a Activity existe.
        UpdaterChannel(this, flutterEngine.dartExecutor.binaryMessenger).register()
    }
}