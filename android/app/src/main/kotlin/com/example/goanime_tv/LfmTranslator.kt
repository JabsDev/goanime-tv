package com.example.goanime_tv

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.nio.ShortBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.locks.ReentrantLock
import java.util.regex.Pattern
import org.json.JSONObject

/// Tradução JA↔EN dedicada (LFM2-350M-ENJP-MT q4f16, causal com cache).
/// Modelo: `onnx-community/LFM2-350M-ENJP-MT-ONNX` (só `model_q4f16.onnx` +
/// `.onnx_data`, normalizados p/ `model.onnx` + `model.onnx_data`).
/// Chat de 1 turno com system prompt de direção ("Translate to English." ou
/// "Translate to Japanese."), greedy, teto 128 tokens novos.
/// Sessão cacheada por modelDir; `dispose` descarrega (carga sequencial).
class LfmTranslator(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val lock = ReentrantLock()
    private val main = Handler(Looper.getMainLooper())
    private var env: OrtEnvironment? = null
    private var loadedDir: String? = null
    private var session: OrtSession? = null
    private var tok: LfmBpe? = null

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        fun reply(fn: () -> Unit) = main.post { runCatching { fn() } }
        when (call.method) {
            "translate" -> Thread {
                try {
                    val out = translate(
                        call.argument<String>("modelDir")!!,
                        call.argument<String>("text")!!,
                        call.argument<String>("srcLang") ?: "ja",
                        call.argument<String>("tgtLang") ?: "en",
                    )
                    reply { result.success(out) }
                } catch (e: Throwable) {
                    // Error (ex. OOM) também vira resposta: exceção não-capturada
                    // em thread mata o app sem mensagem.
                    try { dispose() } catch (_) {}
                    reply { result.error("LFM", e.message, null) }
                }
            }.start()
            "dispose" -> Thread {
                try {
                    dispose()
                    reply { result.success(true) }
                } catch (e: Throwable) {
                    reply { result.error("LFM", e.message, null) }
                }
            }.start()
            else -> result.notImplemented()
        }
    }

    private fun ensureLoaded(modelDir: String) {
        lock.lock()
        try {
            if (loadedDir == modelDir && session != null) return
            disposeLocked()
            env = env ?: OrtEnvironment.getEnvironment()
            val opts = OrtSession.SessionOptions()
            opts.setIntraOpNumThreads(2)
            session = env!!.createSession("$modelDir/model.onnx", opts)
            tok = LfmBpe.load(File("$modelDir/tokenizer.json"))
            loadedDir = modelDir
        } finally {
            lock.unlock()
        }
    }

    fun translate(modelDir: String, text: String, srcLang: String, tgtLang: String): String {
        if (text.isBlank()) return ""
        if (srcLang == tgtLang) return text
        val sys = if (srcLang == "ja") "Translate to English." else "Translate to Japanese."
        ensureLoaded(modelDir)
        val t = tok!!
        // Template de 1 turno (chat_template.jinja do repo, sem tools).
        val prompt = t.encodeWithSpecials(
            "<|im_start|>system\n$sys<|im_end|>\n<|im_start|>user\n$text<|im_end|>\n<|im_start|>assistant\n")
        val promptIds = listOf(1L) + prompt.map { it.toLong() }
        lock.lock()
        try {
            val sess = session!!
            var total = promptIds.size
            // Past inicial zerado (conv [1,1024,3], KV [1,8,0,64]); tipo lido
            // da sessão (KV do q4f16 é float16 — sem chute).
            var past = pastNames(sess).associateWith { name ->
                zeroTensor(sess, name, pastShape(name))
            }
            val gen = mutableListOf<Long>()
            var ids = promptIds
            try {
                while (true) {
                    val m = ids.size
                    val mask = LongArray(total) { 1L }
                    val inputs = mutableMapOf(
                        "input_ids" to OnnxTensor.createTensor(
                            env, LongBuffer.wrap(ids.toLongArray()), longArrayOf(1, m.toLong())),
                        "attention_mask" to OnnxTensor.createTensor(
                            env, LongBuffer.wrap(mask), longArrayOf(1, total.toLong())),
                    )
                    inputs.putAll(past)
                    val next: Long
                    val curPast = past
                    var ok = false
                    try {
                        sess.run(inputs).use { out ->
                            @Suppress("UNCHECKED_CAST")
                            val logits = out.get("logits").get() as Array<Array<FloatArray>>
                            val last = logits[0][logits[0].size - 1]
                            var best = 0
                            var bestV = last[0]
                            for (k in 1 until last.size) {
                                if (last[k] > bestV) {
                                    bestV = last[k]
                                    best = k
                                }
                            }
                            next = best.toLong()
                            past = collectPast(sess, out)
                            ok = true
                        }
                    } finally {
                        // Frescos sempre; past consumido só no sucesso (na falha,
                        // `past` segue válido e o finally externo fecha 1x).
                        runCatching { inputs.getValue("input_ids").close() }
                        runCatching { inputs.getValue("attention_mask").close() }
                        if (ok) curPast.values.forEach { runCatching { it.close() } }
                    }
                    if (next == 7L) break // <|im_end|> = eos
                    gen.add(next)
                    total += 1
                    if (gen.size >= 128) break
                    ids = listOf(next)
                }
            } finally {
                // Presents da última iteração: sem isto, ~1 MB/frase vaza em heap nativo.
                past.values.forEach { runCatching { it.close() } }
            }
            return t.decode(gen.map { it.toInt() }).trim()
        } finally {
            lock.unlock()
        }
    }

    private fun pastNames(sess: OrtSession): List<String> =
        sess.inputNames.filter { it.startsWith("past_") }

    private fun pastShape(name: String): LongArray = when {
        name.startsWith("past_conv") -> longArrayOf(1, 1024, 3)
        else -> longArrayOf(1, 8, 0, 64) // KV vazio no prefill
    }

    private fun zeroTensor(sess: OrtSession, name: String, shape: LongArray): OnnxTensor {
        val n = shape.fold(1L) { a, d -> a * d }.toInt()
        return when (sess.inputInfo[name]!!.info.type) {
            OnnxJavaType.FLOAT -> OnnxTensor.createTensor(env, FloatBuffer.allocate(n), shape)
            OnnxJavaType.FLOAT16 -> OnnxTensor.createTensor(env, ShortBuffer.allocate(n), shape)
            OnnxJavaType.INT64 -> OnnxTensor.createTensor(env, LongBuffer.allocate(n), shape)
            else -> throw IllegalArgumentException("past $name: tipo inesperado")
        }
    }

    private fun collectPast(sess: OrtSession, out: OrtSession.Result): Map<String, OnnxTensor> {
        val into = mutableMapOf<String, OnnxTensor>()
        for (name in out.outputNames) {
            val pastName = when {
                name.startsWith("present_conv") -> name.replace("present_conv", "past_conv")
                name.startsWith("present.") -> name.replace("present.", "past_key_values.")
                else -> continue
            }
            if (!sess.inputNames.contains(pastName)) continue
            val opt = runCatching { out.get(name) }.getOrNull() ?: continue
            if (!opt.isPresent) continue
            (opt.get() as? OnnxTensor)?.let { into[pastName] = it }
        }
        return into
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
        runCatching { session?.close() }
        session = null
        tok = null
        loadedDir = null
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/lfm"
    }
}

/// BPE byte-level estilo GPT-2 lido de `tokenizer.json` (sem dependências).
/// Pré-tokenizador = regex GPT-2 + ByteLevel; merge por rank; decode ByteLevel.
class LfmBpe private constructor(
    private val vocab: Map<String, Int>,
    private val inv: Array<String?>,
    private val ranks: Map<String, Int>,
    private val specials: Map<String, Int>,
) {
    private val splitPattern = Pattern.compile(
        "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+")

    // bytes → unicode (GPT-2 bytes_to_unicode).
    private val byteToUni: CharArray = run {
        val bs = mutableListOf<Int>()
        for (b in '!'.code..'~'.code) bs.add(b)
        for (b in '¡'.code..'¬'.code) bs.add(b)
        for (b in '®'.code..'ÿ'.code) bs.add(b)
        val cs = bs.toMutableList()
        var n = 0
        for (b in 0..255) {
            if (!bs.contains(b)) {
                bs.add(b)
                cs.add(256 + n)
                n++
            }
        }
        CharArray(256) { i -> cs[bs.indexOf(i)].toChar() }
    }
    private val uniToByte: Map<Char, Int> =
        byteToUni.mapIndexed { i, c -> c to i }.toMap()

    private fun bpeWord(piece: String): List<Int> {
        if (piece.isEmpty()) return emptyList()
        vocab[piece]?.let { return listOf(it) }
        var parts = piece.map { it.toString() }
        while (parts.size > 1) {
            var bestRank = Int.MAX_VALUE
            var bestAt = -1
            for (i in 0 until parts.size - 1) {
                val r = ranks["${parts[i]} ${parts[i + 1]}"] ?: continue
                if (r < bestRank) {
                    bestRank = r
                    bestAt = i
                }
            }
            if (bestAt < 0) break
            parts = parts.subList(0, bestAt) +
                (parts[bestAt] + parts[bestAt + 1]) +
                parts.subList(bestAt + 2, parts.size)
        }
        val out = mutableListOf<Int>()
        for (p in parts) {
            // Byte-level cobre todos os bytes: cai p/ chars avulsos se preciso.
            vocab[p]?.let { out.add(it) } ?: run {
                for (c in p) vocab[c.toString()]?.let { out.add(it) }
            }
        }
        return out
    }

    private fun encodeNormal(text: String): List<Int> {
        val out = mutableListOf<Int>()
        val m = splitPattern.matcher(text)
        while (m.find()) {
            val bytes = m.group().toByteArray(Charsets.UTF_8)
            val sb = StringBuilder(bytes.size)
            for (b in bytes) sb.append(byteToUni[b.toInt() and 0xFF])
            out.addAll(bpeWord(sb.toString()))
        }
        return out
    }

    /// Codifica respeitando added tokens (`<|im_start|>` etc. viram ids diretos).
    fun encodeWithSpecials(text: String): List<Int> {
        val out = mutableListOf<Int>()
        val ordered = specials.keys.sortedByDescending { it.length }
        val buf = StringBuilder()
        var i = 0
        while (i < text.length) {
            var hit: String? = null
            for (s in ordered) {
                if (text.startsWith(s, i)) {
                    hit = s
                    break
                }
            }
            if (hit != null) {
                if (buf.isNotEmpty()) {
                    out.addAll(encodeNormal(buf.toString()))
                    buf.clear()
                }
                out.add(specials.getValue(hit))
                i += hit.length
            } else {
                buf.append(text[i])
                i++
            }
        }
        if (buf.isNotEmpty()) out.addAll(encodeNormal(buf.toString()))
        return out
    }

    fun decode(ids: List<Int>): String {
        val sb = StringBuilder()
        for (id in ids) {
            if (id < 0 || id >= inv.size) continue
            val t = inv[id] ?: continue
            if (t.startsWith("<|") && t.endsWith("|>")) continue // special
            sb.append(t)
        }
        val bytes = ByteArray(sb.length)
        var n = 0
        for (c in sb.toString()) {
            val b = uniToByte[c] ?: continue
            bytes[n++] = b.toByte()
        }
        return String(bytes, 0, n, Charsets.UTF_8)
    }

    companion object {
        fun load(file: File): LfmBpe {
            val root = JSONObject(file.readText())
            val model = root.getJSONObject("model")
            val v = model.getJSONObject("vocab")
            val vocab = HashMap<String, Int>(v.length() * 2)
            val keys = v.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                vocab[k] = v.getInt(k)
            }
            val ranks = HashMap<String, Int>()
            val merges = model.getJSONArray("merges")
            for (i in 0 until merges.length()) {
                val e = merges.get(i)
                val pair = if (e is org.json.JSONArray) {
                    "${e.getString(0)} ${e.getString(1)}"
                } else {
                    val s = e as String
                    val sp = s.indexOf(' ')
                    "${s.substring(0, sp)} ${s.substring(sp + 1)}"
                }
                ranks[pair] = i
            }
            var maxId = (vocab.values.maxOrNull() ?: 0)
            val specials = HashMap<String, Int>()
            val added = root.optJSONArray("added_tokens")
            if (added != null) {
                for (i in 0 until added.length()) {
                    val o = added.getJSONObject(i)
                    val id = o.getInt("id")
                    specials[o.getString("content")] = id
                    if (id > maxId) maxId = id
                }
            }
            val inv = arrayOfNulls<String>(maxId + 1)
            for ((k2, id) in vocab) if (id <= maxId) inv[id] = k2
            for ((k2, id) in specials) inv[id] = k2
            return LfmBpe(vocab, inv, ranks, specials)
        }
    }
}
