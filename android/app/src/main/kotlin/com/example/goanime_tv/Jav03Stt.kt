package com.example.goanime_tv

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.locks.ReentrantLock

/// STT whisper-ja-anime-v0.3 pelo ONNX Runtime JA embarcado (o mesmo
/// libonnxruntime.so do sherpa — sem segundo runtime, sem colisao de .so).
/// O nativo (jav03_stt.cpp) so devolve IDs de tokens em CSV; a detokenizacao
/// BPE byte-level fica no Dart.
internal object Jav03Bridge {
    init {
        System.loadLibrary("goanime_jav03_stt")
    }
    external fun nativeLoad(
        melPath: String, encPath: String, decPath: String, threads: Int,
        sot: Long, lang: Long, task: Long, nots: Long, eot: Long
    ): Long
    external fun nativeDecode(handle: Long, audio: FloatArray): String
    external fun nativeFree(handle: Long)
}

class Jav03Stt(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val lock = ReentrantLock()
    private val main = Handler(Looper.getMainLooper())
    private var handle: Long = 0
    private var loadedKey: String? = null

    fun register() { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        fun reply(fn: () -> Unit) = main.post { runCatching { fn() } }
        when (call.method) {
            // modelDir: pasta com mel.onnx/encoder_model.int8.onnx/decoder_model.fp16.onnx
            "decode" -> Thread {
                try {
                    val dir = call.argument<String>("modelDir")!!
                    val files = call.argument<List<String>>("files")!!
                    val threads = call.argument<Int>("threads") ?: 4
                    val audio = call.argument<FloatArray>("audio")!!
                    val ids = call.argument<List<Number>>("promptIds")!!
                        .map { it.toLong() }
                    val out = decode(dir, files, threads, audio, ids)
                    reply { result.success(out) }
                } catch (e: Throwable) {
                    try { dispose() } catch (_: Throwable) {}
                    reply { result.error("JAV03", e.message, null) }
                }
            }.start()
            "dispose" -> Thread {
                try { dispose(); reply { result.success(true) } }
                catch (e: Throwable) { reply { result.error("JAV03", e.message, null) } }
            }.start()
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun ensureLoaded(dir: String, files: List<String>, threads: Int,
                             ids: List<Long>) {
        lock.lock()
        try {
            val key = "$dir|${files.joinToString(",")}|$threads|${ids.joinToString(",")}"
            if (handle != 0L && loadedKey == key) return
            disposeLocked()
            val paths = files.map { "$dir/$it" }
            for (p in paths) {
                if (!File(p).exists()) {
                    throw IllegalStateException("JAV03_CORRUPT: falta ${File(p).name}")
                }
            }
            // ids = [sot, lang, task, nots, eot] do modelo (v0.3 ou student)
            val h = Jav03Bridge.nativeLoad(
                paths[0], paths[1], paths[2], threads,
                ids[0], ids[1], ids[2], ids[3], ids[4])
            if (h == 0L) throw IllegalStateException("JAV03_LOAD: falha ao abrir as sessoes ORT")
            handle = h
            loadedKey = key
        } finally {
            lock.unlock()
        }
    }

    fun decode(dir: String, files: List<String>, threads: Int,
               audio: FloatArray, ids: List<Long>): String {
        ensureLoaded(dir, files, threads, ids)
        val out = Jav03Bridge.nativeDecode(handle, audio)
        // "" = sem fala; o Dart decide (pausa/ruido).
        return out ?: ""
    }

    fun dispose() { lock.lock(); try { disposeLocked() } finally { lock.unlock() } }

    private fun disposeLocked() {
        if (handle != 0L) {
            try { Jav03Bridge.nativeFree(handle) } catch (_: Throwable) {}
            handle = 0
            loadedKey = null
        }
    }

    companion object { const val CHANNEL_NAME = "goanime/jav03_stt" }
}
