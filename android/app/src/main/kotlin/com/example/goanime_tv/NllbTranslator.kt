package com.example.goanime_tv

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.LongBuffer
import java.util.concurrent.locks.ReentrantLock
import kotlin.math.ln

/// Tradução NLLB-600M int8 on-device (L2, aparelho forte).
/// NUNCA `decoder_merged` (crash Reshape no ORT Android): usa `decoder` no
/// passo 0 + `decoder_with_past` nos demais, com past/present descobertos
/// por prefixo de nome. Tokenizer SentencePiece unigram puro-Kotlin
/// ([SpUnigram] + [MiniProto], sem dep de tokenizer).
/// Sessões cacheadas por modelDir; `dispose` descarrega (carga sequencial).
class NllbTranslator(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val lock = ReentrantLock()
    private val main = Handler(Looper.getMainLooper())
    private var env: OrtEnvironment? = null
    private var loadedDir: String? = null
    private var encoder: OrtSession? = null
    private var decoder: OrtSession? = null
    private var decoderPast: OrtSession? = null
    private var sp: SpUnigram? = null

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Resposta sempre na main thread (MethodChannel não é thread-safe).
        fun reply(fn: () -> Unit) = main.post { runCatching { fn() } }
        when (call.method) {
            "translate" -> Thread {
                try {
                    val dir = call.argument<String>("modelDir")!!
                    val text = call.argument<String>("text")!!
                    val src = call.argument<String>("srcLang") ?: "jpn_Jpan"
                    val tgt = call.argument<String>("tgtLang") ?: "por_Latn"
                    val out = translate(dir, text, src, tgt)
                    reply { result.success(out) }
                } catch (e: Exception) {
                    reply { result.error("NLLB", e.message, null) }
                }
            }.start()
            "dispose" -> Thread {
                try {
                    dispose()
                    reply { result.success(true) }
                } catch (e: Exception) {
                    reply { result.error("NLLB", e.message, null) }
                }
            }.start()
            else -> result.notImplemented()
        }
    }

    private fun sessionOptions(modelDir: String): OrtSession.SessionOptions {
        val opts = OrtSession.SessionOptions()
        opts.setIntraOpNumThreads(2)
        // int8 precisa do CPU EP com arena padrão; nada além disso.
        return opts
    }

    private fun ensureLoaded(modelDir: String) {
        lock.lock()
        try {
            if (loadedDir == modelDir && encoder != null) return
            disposeLocked()
            env = env ?: OrtEnvironment.getEnvironment()
            val e = env!!
            encoder = e.createSession("$modelDir/encoder_model.onnx", sessionOptions(modelDir))
            decoder = e.createSession("$modelDir/decoder_model.onnx", sessionOptions(modelDir))
            decoderPast = e.createSession("$modelDir/decoder_with_past_model.onnx", sessionOptions(modelDir))
            sp = SpUnigram.load(File("$modelDir/tokenizer.model"))
            loadedDir = modelDir
        } finally {
            lock.unlock()
        }
    }

    fun translate(modelDir: String, text: String, srcLang: String, tgtLang: String): String {
        ensureLoaded(modelDir)
        val tok = sp!!
        val encIds = (tok.encode(text) + listOf(tok.eosId, tok.idOf(srcLang))).map { it.toLong() }.toLongArray()
        val n = encIds.size
        val hidden: Array<Array<FloatArray>>
        val encMask = LongArray(n) { 1L }
        lock.lock()
        try {
            val enc = encoder!!
            val encIn = mapOf(
                enc.inputNames.first() to OnnxTensor.createTensor(env, LongBuffer.wrap(encIds), longArrayOf(1, n.toLong())),
                enc.inputNames.elementAtOrElse(1) { enc.inputNames.first() } to
                    OnnxTensor.createTensor(env, LongBuffer.wrap(encMask), longArrayOf(1, n.toLong())),
            )
            enc.run(encIn).use { out ->
                @Suppress("UNCHECKED_CAST")
                hidden = out.get(enc.outputNames.first()).get() as Array<Array<FloatArray>>
            }
            val dec = decoder!!
            val decPast = decoderPast!!
            val decIn = dec.inputNames.toList()
            val decPastIn = decPast.inputNames.toList()
            val decLogitsName = dec.outputNames.first()
            val decPastLogitsName = decPast.outputNames.first()
            val bosTgt = tok.idOf(tgtLang).toLong()
            val decHidden = hidden[0] // [n, h]
            val h = decHidden[0].size
            val flatHidden = FloatArray(n * h) { i -> decHidden[i / h][i % h] }
            val gen = mutableListOf<Long>()
            gen.add(bosTgt)
            var past: Map<String, OnnxTensor>? = null
            for (step in 0 until 128) {
                val m = gen.size
                val logits: Array<Array<FloatArray>>
                val newPast = mutableMapOf<String, OnnxTensor>()
                // Com past válido usa decoder_with_past (1 token); senão o
                // decoder cheio com o prefixo (export sem presents).
                val cur = past
                if (cur != null && cur.isNotEmpty()) {
                    val inputs = mutableMapOf<String, OnnxTensor>(
                        decPastIn[0] to OnnxTensor.createTensor(
                            env, LongBuffer.wrap(longArrayOf(gen.last())), longArrayOf(1, 1)),
                    )
                    for (name in decPastIn.drop(1)) {
                        when {
                            name.contains("attention", ignoreCase = true) ||
                                name.contains("mask", ignoreCase = true) ->
                                inputs[name] = if (name.contains("encoder", ignoreCase = true)) {
                                    OnnxTensor.createTensor(env, LongBuffer.wrap(encMask), longArrayOf(1, n.toLong()))
                                } else {
                                    OnnxTensor.createTensor(env, LongBuffer.wrap(LongArray(m) { 1L }), longArrayOf(1, m.toLong()))
                                }
                            name.contains("encoder_hidden", ignoreCase = true) ->
                                inputs[name] = OnnxTensor.createTensor(
                                    env, java.nio.FloatBuffer.wrap(flatHidden), longArrayOf(1, n.toLong(), h.toLong()))
                            name.startsWith("past") && cur.containsKey(name) ->
                                inputs[name] = cur.getValue(name)
                        }
                    }
                    decPast.run(inputs).use { out ->
                        @Suppress("UNCHECKED_CAST")
                        logits = out.get(decPastLogitsName).get() as Array<Array<FloatArray>>
                        collectPrefixed(out, decPast.outputNames, "present", newPast)
                    }
                    cur.values.forEach { runCatching { it.close() } }
                } else {
                    val inputs = mutableMapOf(
                        decIn[0] to OnnxTensor.createTensor(env, LongBuffer.wrap(gen.toLongArray()), longArrayOf(1, m.toLong())),
                        decIn[1] to OnnxTensor.createTensor(
                            env,
                            java.nio.FloatBuffer.wrap(flatHidden),
                            longArrayOf(1, n.toLong(), h.toLong())),
                    )
                    if (decIn.size > 2) {
                        inputs[decIn[2]] = OnnxTensor.createTensor(env, LongBuffer.wrap(encMask), longArrayOf(1, n.toLong()))
                    }
                    dec.run(inputs).use { out ->
                        @Suppress("UNCHECKED_CAST")
                        logits = out.get(decLogitsName).get() as Array<Array<FloatArray>>
                        collectPrefixed(out, dec.outputNames, "present", newPast)
                    }
                }
                past = newPast
                val last = logits[0][logits[0].size - 1]
                var best = 0
                var bestV = last[0]
                for (k in 1 until last.size) {
                    if (last[k] > bestV) {
                        bestV = last[k]
                        best = k
                    }
                }
                if (best == tok.eosId) break
                gen.add(best.toLong())
            }
            past?.values?.forEach { runCatching { it.close() } }
            return tok.decode(gen.drop(1).map { it.toInt() })
        } finally {
            lock.unlock()
        }
    }

    private fun collectPrefixed(
        out: OrtSession.Result,
        names: Set<String>,
        prefix: String,
        into: MutableMap<String, OnnxTensor>,
    ) {
        for (name in names) {
            if (!name.startsWith(prefix)) continue
            val opt = runCatching { out.get(name) }.getOrNull() ?: continue
            if (!opt.isPresent) continue
            (opt.get() as? OnnxTensor)?.let {
                into[name.replace("present", "past")] = it
            }
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

    private fun disposeLocked() {
        runCatching { encoder?.close() }
        runCatching { decoder?.close() }
        runCatching { decoderPast?.close() }
        encoder = null
        decoder = null
        decoderPast = null
        sp = null
        loadedDir = null
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/nllb"
    }
}

/// Leitor protobuf mínimo: só varint + len-delimited + skip. Extrai as peças
/// do ModelProto do SentencePiece sem dependência externa.
object MiniProto {
    data class Field(val num: Int, val wire: Int, val bytes: ByteArray?, val vint: Long)

    fun parse(buf: ByteArray, from: Int = 0, to: Int = buf.size): List<Field> {
        val out = mutableListOf<Field>()
        var p = from
        while (p < to) {
            val (key, p1) = varint(buf, p)
            p = p1
            val num = (key shr 3).toInt()
            val wire = (key and 7).toInt()
            when (wire) {
                0 -> {
                    val (v, p2) = varint(buf, p)
                    p = p2
                    out.add(Field(num, wire, null, v))
                }
                2 -> {
                    val (len, p2) = varint(buf, p)
                    p = p2
                    out.add(Field(num, wire, buf.copyOfRange(p, p + len.toInt()), 0))
                    p += len.toInt()
                }
                1 -> {
                    p += 8
                    out.add(Field(num, wire, null, 0))
                }
                5 -> {
                    p += 4
                    out.add(Field(num, wire, null, 0))
                }
                else -> throw IllegalArgumentException("wire $wire")
            }
        }
        return out
    }

    fun varint(buf: ByteArray, p0: Int): Pair<Long, Int> {
        var p = p0
        var shift = 0
        var v = 0L
        while (true) {
            val b = buf[p++].toInt() and 0xFF
            v = v or ((b and 0x7F).toLong() shl shift)
            if (b and 0x80 == 0) break
            shift += 7
        }
        return v to p
    }

    fun string(bytes: ByteArray): String = String(bytes, Charsets.UTF_8)
}

/// Unigram SentencePiece: Viterbi sobre as peças (teto len 16) + decode ▁.
/// Suficiente p/ NLLB (vocab 256k; greedy por posição, O(n·16)).
class SpUnigram private constructor(
    val pieces: List<String>,
    val scores: FloatArray,
    val ids: Map<String, Int>,
    val eosId: Int,
) {
    fun idOf(token: String): Int =
        ids[token] ?: ids["<unk>"] ?: throw IllegalStateException("sem <unk>")

    fun encode(text: String): List<Int> {
        val s = "▁" + text.replace(Regex("\\s+"), "▁")
        val n = s.length
        val best = DoubleArray(n + 1) { Double.NEGATIVE_INFINITY }
        val back = IntArray(n + 1)
        val backLen = IntArray(n + 1)
        best[0] = 0.0
        var i = 0
        while (i < n) {
            if (best[i] == Double.NEGATIVE_INFINITY) {
                i++
                continue
            }
            val maxL = minOf(16, n - i)
            var l = 1
            while (l <= maxL) {
                val sub = s.substring(i, i + l)
                val id = ids[sub]
                if (id != null) {
                    val score = best[i] + scores[id].toDouble()
                    if (score > best[i + l]) {
                        best[i + l] = score
                        back[i + l] = id
                        backLen[i + l] = l
                    }
                }
                l++
            }
            // fallback: byte (unk) consome 1 char
            if (best[i + 1] == Double.NEGATIVE_INFINITY) {
                best[i + 1] = best[i] + ln(1e-9)
                back[i + 1] = ids["<unk>"]!!
                backLen[i + 1] = 1
            }
            i++
        }
        val out = mutableListOf<Int>()
        var p = n
        while (p > 0) {
            out.add(back[p])
            p -= backLen[p]
        }
        return out.reversed()
    }

    fun decode(ids: List<Int>): String {
        val sb = StringBuilder()
        for (id in ids) {
            if (id == eosId) break
            val t = pieces.getOrElse(id) { "" }
            if (t.startsWith("▁")) sb.append(' ').append(t.drop(1)) else sb.append(t)
        }
        return sb.toString().trim().replace(Regex("\\s+([.,!?;:…%)])"), "$1")
    }

    companion object {
        fun load(file: File): SpUnigram {
            val root = MiniProto.parse(file.readBytes())
            val names = mutableListOf<String>()
            val sc = mutableListOf<Float>()
            var eos = 2
            for (f in root) {
                if (f.num != 1 || f.bytes == null) continue // repeated pieces
                val sub = MiniProto.parse(f.bytes)
                var piece: String? = null
                var score = 0f
                var type = 0
                for (s in sub) {
                    when (s.num) {
                        1 -> piece = MiniProto.string(s.bytes ?: byteArrayOf())
                        2 -> score = java.lang.Float.intBitsToFloat(s.vint.toInt())
                        3 -> type = s.vint.toInt()
                    }
                }
                if (piece != null) {
                    // type 3 = BPE? NLLB usa unigram: mantém tudo; controla eos.
                    if (piece == "</s>") eos = names.size
                    names.add(piece)
                    sc.add(score)
                    if (type == 3) {
                        // byte fallback mapeado p/ unk no encode
                    }
                }
            }
            val ids = HashMap<String, Int>(names.size * 2)
            names.forEachIndexed { i, t -> ids.putIfAbsent(t, i) }
            return SpUnigram(names, sc.toFloatArray(), ids, eos)
        }
    }
}
