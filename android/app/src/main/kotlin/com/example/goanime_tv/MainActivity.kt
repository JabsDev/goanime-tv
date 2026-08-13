package com.example.goanime_tv

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var updaterChannel: UpdaterChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Registro único (singleTop nunca recria a Activity): o canal do
        // update vive enquanto a Activity existe.
        updaterChannel = UpdaterChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        updaterChannel?.register()
    }

    // A instalação via ACTION_INSTALL_PACKAGE devolve o resultado aqui
    // (EXTRA_RETURN_RESULT); repassa para o canal do updater.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        updaterChannel?.onActivityResult(requestCode, resultCode, data)
    }
}
