package com.example.goanime_tv

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.locks.ReentrantLock

/// Tradução local via llama.cpp (GGUF, CPU): Hy-MT2 JA→PT direto + EN→PT.
/// Sessão nativa cacheada por modelPath (load de ~1 GB amortizado entre
/// frases); `dispose` descarrega (carga sequencial com o STT).
/// Prompt = template de 1 turno do model card, greedy (temp 0), teto 96.
internal object LlmBridge {
    init {
        System.loadLibrary("goanime_llm")
    }

    external fun nativeLoad(modelPath: String): Long
    external fun nativeGenerate(handle: Long, prompt: String, maxTokens: Int): String?

    /** Como [nativeGenerate], mas aplica o template de chat embutido no GGUF
     *  (usado pelo auditor: gemma-3 precisa dos tokens <start_of_turn>). */
    external fun nativeGenerateChat(handle: Long, prompt: String, maxTokens: Int): String?
    external fun nativeFree(handle: Long)
}

class LlmTranslator(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val lock = ReentrantLock()
    private val main = Handler(Looper.getMainLooper())
    private var handle: Long = 0
    private var loadedPath: String? = null

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        fun reply(fn: () -> Unit) = main.post { runCatching { fn() } }
        when (call.method) {
            "translate" -> Thread {
                try {
                    val out = translate(
                        call.argument<String>("modelPath")!!,
                        call.argument<String>("text")!!,
                        call.argument<String>("srcLang") ?: "ja",
                        call.argument<String>("tgtLang") ?: "pt",
                    )
                    reply { result.success(out) }
                } catch (e: Throwable) {
                    // Error nativo também vira resposta (sem morte silenciosa).
                    try { dispose() } catch (_: Throwable) {}
                    reply { result.error("LLM", e.message, null) }
                }
            }.start()
            "dispose" -> Thread {
                try {
                    dispose()
                    reply { result.success(true) }
                } catch (e: Throwable) {
                    reply { result.error("LLM", e.message, null) }
                }
            }.start()
            // Auditor de legenda: prompt cru do Dart (disciplina de auditoria
            // própria, diferente do template do tradutor).
            "audit" -> Thread {
                try {
                    val out = audit(
                        call.argument<String>("modelPath")!!,
                        call.argument<String>("prompt")!!,
                        call.argument<Int>("maxTokens") ?: 160,
                    )
                    reply { result.success(out) }
                } catch (e: Throwable) {
                    try { dispose() } catch (_: Throwable) {}
                    reply { result.error("LLM", e.message, null) }
                }
            }.start()
            else -> result.notImplemented()
        }
    }

    private fun ensureLoaded(modelPath: String) {
        lock.lock()
        try {
            if (handle != 0L && loadedPath == modelPath) return
            disposeLocked()
            // Variável local: -1 (OOM) nunca é persistido no field —
            // nativeFree(-1) seria crash (ponteiro inválido).
            val f = java.io.File(modelPath)
            val exists = try { f.exists() } catch (_: Throwable) { false }
            val bytes = try { f.length() } catch (_: Throwable) { -1L }
            val h = LlmBridge.nativeLoad(modelPath)
            if (h == 0L) throw IllegalStateException(
                "LLM_CORRUPT: $modelPath (existe=$exists bytes=$bytes)")
            if (h == -1L) throw IllegalStateException(
                "LLM_OOM: $modelPath (bytes=$bytes)")
            handle = h
            loadedPath = modelPath
        } finally {
            lock.unlock()
        }
    }

    fun translate(modelPath: String, text: String, srcLang: String, tgtLang: String): String {
        if (text.isBlank()) return ""
        if (srcLang == tgtLang) return text
        ensureLoaded(modelPath)
        // Template do model card (user-only, sem system): instrução embutida.
        // Formato validado no spike contra o template Jinja do modelo.
        val langName = mapOf(
            "pt" to "Portuguese",
            "ja" to "Japanese",
            "en" to "English",
            "es" to "Spanish",
        )
        val tgt = langName[tgtLang]
            ?: throw IllegalArgumentException("alvo $tgtLang sem suporte")
        val src = langName[srcLang] ?: srcLang
        // LMT-60 (NiuTrans) é tradutor dedicado: usa o formato do model card
        // ("Translate the following text from Japanese into Portuguese:\n
        // Japanese: ...\nPortuguese:"). Instrução genérica degrada a qualidade.
        // Qwen3 abre modo thinking que come o teto de tokens (H2):
        // "/no_think" desliga no prompt (o strip_think no C++ cobre o resto).
        val lower = modelPath.lowercase()
        val isLmt = lower.contains("lmt")
        // Hy-MT2 (Hunyuan MT) NÃO tem chat template (tokens <|hy_...|>): envolver
        // em <|im_start|> vira texto literal e o modelo alucina (visto no EP3).
        // Vai prompt cru, no formato do model card.
        val isHy = lower.contains("hymt") || lower.contains("hy-mt")
        val body = when {
            isLmt -> "Translate the following text from $src into $tgt:\n$src: $text\n$tgt:"
            isHy -> "Translate the following text into $tgt. Note that you should " +
                "only output the translated result without any additional explanation:" +
                "\n\n$text"
            else -> "Translate the following subtitle text into $tgt. " +
                "Keep it concise, as subtitles: at most 2 short lines. " +
                "Note that you should only output the translated result " +
                "without any additional explanation:\n\n$text"
        }
        val withHint = if (modelPath.contains("qwen", ignoreCase = true)) {
            "$body /no_think"
        } else body
        // Hy-MT2: prompt puro. Demais: template ChatML (Qwen3/LFM).
        val prompt = if (isHy) withHint
        else "<|im_start|>user\n$withHint<|im_end|>\n<|im_start|>assistant\n"
        lock.lock()
        try {
            // Sessão persistente: KV do prompt anterior é limpo no JNI por chamada.
            // Teto 96 (era 128): legenda de 2 linhas cabe folgado e corta o
            // pior caso (runaway) — o stop real agora é eot/<|im_end|>.
            return (LlmBridge.nativeGenerate(handle, prompt, 96) ?: "").trim()
        } finally {
            lock.unlock()
        }
    }

    fun dispose() {
        lock.lock()
        try {
            disposeLocked()
        } finally {
            lock.unlock()
        }
    }

    /// Auditor de legenda: recebe o prompt (já montado no Dart, com a
    /// disciplina própria de auditoria) e gera, aplicando o TEMPLATE DE CHAT
    /// embutido no GGUF (nativeGenerateChat). É o que evita o runaway: sem os
    /// tokens do template (ex.: gemma-3 <start_of_turn>user/model), o modelo
    /// continua o texto até o teto. O Dart manda a mensagem de usuário "crua"
    /// (instrução + linha); o template de chat é responsabilidade do runtime.
    fun audit(modelPath: String, prompt: String, maxTokens: Int): String {
        ensureLoaded(modelPath)
        lock.lock()
        try {
            return (LlmBridge.nativeGenerateChat(handle, prompt, maxTokens) ?: "")
                .trim()
        } finally {
            lock.unlock()
        }
    }

    private fun disposeLocked() {
        if (handle != 0L && handle != -1L) {
            runCatching { LlmBridge.nativeFree(handle) }
            handle = 0
        } else if (handle == -1L) {
            handle = 0
        }
        loadedPath = null
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/llm"
    }
}
