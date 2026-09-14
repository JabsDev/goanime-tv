package com.example.goanime_tv

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// Extração de áudio + tracks de legenda sem ffmpeg-kit (abandonado).
///
/// - `getSubtitleTracks{path|url,headers}`: lista tracks `subtitle/*` via
///   `MediaExtractor` (Rota S: extrai legenda embutida sem Whisper).
/// - `extractPcm16k{path|url,headers,outPath}`: PCM 16 kHz mono 16-bit via
///   `MediaExtractor` + `MediaCodec` (entrada do STT sherpa_onnx, Fase 2).
/// Trabalho pesado roda em thread própria; `cancel:true` interrompe.
class AudioExtractChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var cancelled = false

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cancel" -> {
                cancelled = true
                result.success(true)
            }
            // Gating L2 (plano §L2): disco livre p/ NLLB (~2GB).
            "freeSpaceBytes" -> {
                try {
                    val path = call.argument<String>("path")
                        ?: throw IllegalArgumentException("path ausente")
                    result.success(android.os.StatFs(path).availableBytes)
                } catch (e: Exception) {
                    result.error("DISK", e.message, null)
                }
            }
            "getSubtitleTracks" -> Thread {
                try {
                    @Suppress("UNCHECKED_CAST")
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    val tracks = listSubtitleTracks(
                        call.argument<String>("url") ?: call.argument<String>("path")!!,
                        headers,
                    )
                    main.post { runCatching { result.success(tracks) } }
                } catch (e: Exception) {
                    main.post { runCatching { result.error("SUBS", e.message, null) } }
                }
            }.start()
            "extractPcm16k" -> Thread {
                try {
                    cancelled = false
                    @Suppress("UNCHECKED_CAST")
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    val out = extractPcm16k(
                        call.argument<String>("url") ?: call.argument<String>("path")!!,
                        headers,
                        call.argument<String>("outPath")!!,
                    )
                    main.post { runCatching { result.success(out) } }
                } catch (e: Exception) {
                    main.post { runCatching { result.error("PCM", e.message, null) } }
                }
            }.start()
            else -> result.notImplemented()
        }
    }

    private fun dataSource(pathOrUrl: String, headers: Map<String, String>): Pair<String, Map<String, String>?> {
        return if (pathOrUrl.startsWith("http")) pathOrUrl to headers else pathOrUrl to null
    }

    fun listSubtitleTracks(pathOrUrl: String, headers: Map<String, String>): List<Map<String, Any?>> {
        val ext = MediaExtractor()
        val (src, h) = dataSource(pathOrUrl, headers)
        if (h == null) ext.setDataSource(src) else ext.setDataSource(src, h)
        try {
            val out = mutableListOf<Map<String, Any?>>()
            for (i in 0 until ext.trackCount) {
                val fmt = ext.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("subtitle/") && mime != "text/vtt" && mime != "application/x-subrip") continue
                out.add(
                    mapOf(
                        "index" to i,
                        "mime" to mime,
                        "language" to (runCatching { fmt.getString(MediaFormat.KEY_LANGUAGE) }.getOrNull()),
                    ),
                )
            }
            return out
        } finally {
            ext.release()
        }
    }

    fun extractPcm16k(pathOrUrl: String, headers: Map<String, String>, outPath: String): Map<String, Any> {
        val ext = MediaExtractor()
        val (src, h) = dataSource(pathOrUrl, headers)
        if (h == null) ext.setDataSource(src) else ext.setDataSource(src, h)
        try {
            var audioIdx = -1
            var srcRate = 0
            var srcCh = 0
            for (i in 0 until ext.trackCount) {
                val fmt = ext.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audioIdx = i
                    srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    srcCh = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    break
                }
            }
            require(audioIdx >= 0) { "sem track de áudio" }
            ext.selectTrack(audioIdx)
            val srcFmt = ext.getTrackFormat(audioIdx)
            val mime = srcFmt.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(srcFmt, null, null, 0)
            codec.start()
            val out = File(outPath)
            out.parentFile?.mkdirs()
            // PCM cru 16 kHz mono 16-bit LE (sherpa_onnx espera este formato).
            // Downmix: média dos canais; resample: nearest-neighbor.
            val info = MediaCodec.BufferInfo()
            var sawInputEos = false
            var sawOutputEos = false
            out.outputStream().buffered().use { fos ->
                val ratio = srcRate / 16000.0
                var srcPos = 0L
                var nextOut = 0L
                while (!sawOutputEos) {
                    if (cancelled) throw InterruptedException("cancelado")
                    if (!sawInputEos) {
                        val ib = codec.dequeueInputBuffer(10_000)
                        if (ib >= 0) {
                            val buf = codec.getInputBuffer(ib)!!
                            val n = ext.readSampleData(buf, 0)
                            if (n < 0) {
                                codec.queueInputBuffer(ib, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                sawInputEos = true
                            } else {
                                codec.queueInputBuffer(ib, 0, n, ext.sampleTime, 0)
                                ext.advance()
                            }
                        }
                    }
                    val ob = codec.dequeueOutputBuffer(info, 10_000)
                    if (ob >= 0) {
                        if (info.size > 0) {
                            val buf = codec.getOutputBuffer(ob)!!.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                            val shorts = ShortArray(info.size / 2)
                            buf.asShortBuffer().get(shorts)
                            // média dos canais -> mono, nearest-neighbor -> 16k
                            val mono = ShortArray(shorts.size / srcCh.coerceAtLeast(1)) { k ->
                                var acc = 0
                                for (c in 0 until srcCh.coerceAtLeast(1)) acc += shorts[k * srcCh.coerceAtLeast(1) + c]
                                (acc / srcCh.coerceAtLeast(1)).toShort()
                            }
                            val le = ByteBuffer.allocate(mono.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                            for (s in mono) {
                                if (srcPos.toDouble() / ratio >= nextOut) {
                                    le.putShort(s)
                                    nextOut++
                                }
                                srcPos++
                            }
                            fos.write(le.array(), 0, le.position())
                        }
                        codec.releaseOutputBuffer(ob, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEos = true
                    }
                }
            }
            codec.stop()
            codec.release()
            return mapOf("pcmPath" to outPath, "sampleRate" to 16000, "channels" to 1)
        } finally {
            ext.release()
        }
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/audio_extract"
    }
}
