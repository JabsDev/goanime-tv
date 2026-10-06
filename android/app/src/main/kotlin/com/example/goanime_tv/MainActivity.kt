package com.example.goanime_tv

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/// Activity principal.
///
/// Usa a engine CACHEADA por [GoAnimeApp] (getCachedEngineId fixo): a engine
/// nunca é criada nem destruída aqui — sobrevive ao destroy da Activity
/// (deslizar dos recentes) enquanto o SubtitleJobService segura o processo.
/// Os canais do pipeline (Codecs/AudioExtract/Llm/SubtitleJob) são
/// registrados na engine pelo Application; aqui ficam só os canais que
/// precisam de Activity, re-registrados a cada attach (handler substitui).
class MainActivity : FlutterActivity() {
    private var updaterChannel: UpdaterChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Registro único (singleTop nunca recria a Activity): o canal do
        // update vive enquanto a Activity existe.
        updaterChannel = UpdaterChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        updaterChannel?.register()
        // UiModeChannel vive no Application (GoAnimeApp): o Dart consulta o
        // modo TV×celular antes de qualquer Activity existir.
        live = this
    }

    // Engine fixa do Application (nunca "engine própria da Activity").
    override fun getCachedEngineId(): String = GoAnimeApp.ENGINE_ID

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (live === this) live = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // A instalação via ACTION_INSTALL_PACKAGE devolve o resultado aqui
    // (EXTRA_RETURN_RESULT); repassa para o canal do updater.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        updaterChannel?.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        /// Ref da Activity viva p/ pedidos de permissão (notificações, 13+).
        @Volatile
        var live: MainActivity? = null
            private set

        const val REQ_NOTIFICATIONS = 4242
    }
}
