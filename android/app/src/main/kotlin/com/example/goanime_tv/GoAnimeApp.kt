package com.example.goanime_tv

import android.app.Application
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/// Application que pré-aquece a FlutterEngine e a mantém CACHEADA no processo.
///
/// Por que: o job de legenda IA vive no Dart (fila no SubtitleJobManager, STT
/// via sherpa/FFI, extração de áudio via canal, tradução via JNI/llama.cpp).
/// Com a engine pertencendo à Activity, "deslizar o app dos recentes" destrói
/// a engine e o job morre no meio. Com a engine cacheada:
/// - a engine sobrevive ao destroy da MainActivity (MainActivity retornando
///   sempre ENGINE_ID em getCachedEngineId);
/// - o SubtitleJobService (foreground `dataSync`) segura o processo vivo e a
///   CPU acordada enquanto houver job — usar o celular p/ outra coisa funciona;
/// - reabrir o app reata a MESMA engine: a tela volta com o progresso vivo do
///   card (mesmo isolate, mesmos ValueNotifier(s)).
///
/// Efeitos colaterais aceitos: `main()` roda no onCreate do processo (antes da
/// Activity) e a engine fica residente até o SO matar o processo — igual ao
/// comportamento antigo de "app em memória", só que agora com dono claro.
class GoAnimeApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // FlutterEngine(context) registra o GeneratedPluginRegistrant durante
        // a construção; o registerWith explícito é rede de segurança (a engine
        // deduplica "already registered").
        val engine = FlutterEngine(this)
        io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        JobBridge.engine = engine

        val messenger = engine.dartExecutor.binaryMessenger
        // Canais do pipeline de legenda (sem dependência de Activity): vivem
        // na engine, não na tela — continuam respondendo com o app em fundo.
        CodecsChannel(messenger).register()
        AudioExtractChannel(messenger).register()
        LlmTranslator(messenger).register()
        Jav03Stt(messenger).register()
        Seq2SeqAudit(messenger).register()
        SubtitleJobChannel(this, messenger).register()
        // UiMode NÃO depende de Activity, mas PRECISA estar pronto antes de
        // `main()` (que roda logo abaixo): o Dart chama `getUiModeType` no boot
        // para decidir TV×celular. Registrado aqui (e não só no MainActivity)
        // porque a engine é cacheada e o entrypoint executa antes de qualquer
        // Activity — registrar depois causava corrida e a TV era tratada como
        // celular (retrato/esticado).
        UiModeChannel(this, messenger).register()

        // main() roda aqui (headless até a Activity anexar o FlutterView).
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }

    companion object {
        const val ENGINE_ID = "goanime_main_engine"
    }
}

/// Ponte estática processo↔engine: o serviço (que não tem engine própria)
/// alcança o Dart pelo messenger da engine cacheada, mesmo com a Activity
/// destruída. Ex.: o botão "Cancelar" da notificação chega no Dart aqui.
internal object JobBridge {
    @Volatile var engine: FlutterEngine? = null
    private val main = Handler(Looper.getMainLooper())

    fun postToDart(method: String, args: Any?) {
        val eng = engine ?: return
        main.post {
            runCatching {
                MethodChannel(eng.dartExecutor.binaryMessenger, SubtitleJobChannel.CHANNEL_NAME)
                    .invokeMethod(method, args)
            }
        }
    }
}
