package com.example.goanime_tv

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.locks.ReentrantLock

/// Auditor JA seq2seq (ByT5 fine-tunado) pelo ONNX Runtime JA embarcado.
/// O nativo (audit_seq2seq.cpp) cuida do byte-level (id = byte+3, EOS) — sem
/// tokenizer externo. Sessao cacheada por (dir, arquivos, threads).
internal object Seq2SeqBridge {
    init {
        System.loadLibrary("goanime_audit")
    }
    external fun nativeLoad(encPath: String, decPath: String, threads: Int): Long
    external fun nativeFix(handle: Long, text: String): String?
    external fun nativeFree(handle: Long)
}

class Seq2SeqAudit(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val lock = ReentrantLock()
    private val main = Handler(Looper.getMainLooper())
    private var handle: Long = 0
    private var loadedKey: String? = null

    fun register() { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        fun reply(fn: () -> Unit) = main.post { runCatching { fn() } }
        when (call.method) {
            "fix" -> Thread {
                try {
                    val dir = call.argument<String>("modelDir")!!
                    val enc = call.argument<String>("encoder") ?: "encoder.int8.onnx"
                    val dec = call.argument<String>("decoder") ?: "decoder.int8.onnx"
                    val threads = call.argument<Int>("threads") ?: 4
                    val text = call.argument<String>("text")!!
                    reply { result.success(fix(dir, enc, dec, threads, text)) }
                } catch (e: Throwable) {
                    try { dispose() } catch (_: Throwable) {}
                    reply { result.error("SEQ2SEQ", e.message, null) }
                }
            }.start()
            "dispose" -> Thread {
                try { dispose(); reply { result.success(true) } }
                catch (e: Throwable) { reply { result.error("SEQ2SEQ", e.message, null) } }
            }.start()
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun ensureLoaded(dir: String, enc: String, dec: String, threads: Int) {
        lock.lock()
        try {
            val key = "$dir|$enc|$dec|$threads"
            if (handle != 0L && loadedKey == key) return
            disposeLocked()
            val encPath = "$dir/$enc"
            val decPath = "$dir/$dec"
            for (p in listOf(encPath, decPath)) {
                if (!File(p).exists()) {
                    throw IllegalStateException("SEQ2SEQ_CORRUPT: falta ${File(p).name}")
                }
            }
            val h = Seq2SeqBridge.nativeLoad(encPath, decPath, threads)
            if (h == 0L) throw IllegalStateException("SEQ2SEQ_LOAD: falha ao abrir as sessoes ORT")
            handle = h
            loadedKey = key
        } finally {
            lock.unlock()
        }
    }

    fun fix(dir: String, enc: String, dec: String, threads: Int, text: String): String {
        ensureLoaded(dir, enc, dec, threads)
        return Seq2SeqBridge.nativeFix(handle, text) ?: ""
    }

    fun dispose() { lock.lock(); try { disposeLocked() } finally { lock.unlock() } }

    private fun disposeLocked() {
        if (handle != 0L) {
            try { Seq2SeqBridge.nativeFree(handle) } catch (_: Throwable) {}
            handle = 0
            loadedKey = null
        }
    }

    companion object { const val CHANNEL_NAME = "goanime/seq2seq_audit" }
}
