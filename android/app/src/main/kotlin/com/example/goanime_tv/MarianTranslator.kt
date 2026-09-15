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
import org.json.JSONObject

/// Tradução Marian leve (Rota S, EN/ES→PT) via ORT Android.
/// Modelo: Xenova `opus-mt-en-mul` int8 (encoder + decoder, sem past —
/// recomputa o prefixo; teto 128 tokens, ok p/ cue curta) + `vocab.json`.
/// Multilíngue exige o alvo na entrada (`>>por<<`, via `targetPrefix`).
/// `decoder_start/eos` lidos de `generation_config.json` (sem chute).
/// Sessão cacheada por modelDir; `dispose` descarrega (carga sequencial).
class MarianTranslator(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val lock = ReentrantLock()
    private val main = Handler(Looper.getMainLooper())
    private var env: OrtEnvironment? = null
    private var loadedDir: String? = null
    private var encoder: OrtSession? = null
    private var decoder: OrtSession? = null
    private var vocab: Map<String, Int>? = null
    private var decStartId = 0
    private var eosId = 0

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
                        call.argument<String>("targetPrefix"),
                    )
                    reply { result.success(out) }
                } catch (e: Throwable) {
                    // Error (ex. OOM) também vira resposta: exceção não-capturada
                    // em thread mata o app sem mensagem. Best-effort: solta as sessões.
                    try { dispose() } catch (_: Throwable) {}
                    reply { result.error("MARIAN", e.message, null) }
                }
            }.start()
            "dispose" -> Thread {
                try {
                    dispose()
                    reply { result.success(true) }
                } catch (e: Throwable) {
                    reply { result.error("MARIAN", e.message, null) }
                }
            }.start()
            else -> result.notImplemented()
        }
    }

    private fun ensureLoaded(modelDir: String) {
        lock.lock()
        try {
            if (loadedDir == modelDir && encoder != null) return
            disposeLocked()
            env = env ?: OrtEnvironment.getEnvironment()
            val e = env!!
            val opts = OrtSession.SessionOptions()
            opts.setIntraOpNumThreads(2)
            encoder = e.createSession("$modelDir/encoder_model.onnx", opts)
            decoder = e.createSession("$modelDir/decoder_model.onnx", opts)
            val v = JSONObject(File("$modelDir/vocab.json").readText())
            val map = HashMap<String, Int>(v.length() * 2)
            val keys = v.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                map[k] = v.getInt(k)
            }
            vocab = map
            val gen = JSONObject(File("$modelDir/generation_config.json").readText())
            decStartId = gen.optInt("decoder_start_token_id", map["<pad>"] ?: 0)
            eosId = gen.optInt("eos_token_id", map["</s>"] ?: 0)
            loadedDir = modelDir
        } finally {
            lock.unlock()
        }
    }

    fun translate(modelDir: String, text: String, targetPrefix: String?): String {
        ensureLoaded(modelDir)
        val tok = vocab!!
        val unk = tok["<unk>"] ?: 0
        var ids = encode(tok, unk, text).take(62).toMutableList()
        if (targetPrefix != null) {
            val pid = tok[targetPrefix] ?: throw IllegalArgumentException("prefixo $targetPrefix fora do vocab")
            ids.add(0, pid)
        }
        lock.lock()
        try {
            val enc = encoder!!
            val dec = decoder!!
            val n = ids.size
            val encMask = LongArray(n) { 1L }
            val hidden: Array<Array<FloatArray>>
            val idsTensor = OnnxTensor.createTensor(env, LongBuffer.wrap(ids.map { it.toLong() }.toLongArray()), longArrayOf(1, n.toLong()))
            val maskTensor = OnnxTensor.createTensor(env, LongBuffer.wrap(encMask), longArrayOf(1, n.toLong()))
            val encIn = mapOf(
                enc.inputNames.first() to idsTensor,
                enc.inputNames.elementAtOrElse(1) { enc.inputNames.first() } to maskTensor,
            )
            try {
                enc.run(encIn).use { out ->
                    @Suppress("UNCHECKED_CAST")
                    hidden = out.get(enc.outputNames.first()).get() as Array<Array<FloatArray>>
                }
            } finally {
                // Tensores de entrada também seguram heap nativo: fechar sempre.
                // Sem isto, EP inteiro (centenas de frases) vaza até OOM silencioso.
                // Fecha os objetos (não os valores do map: com 1 input, o map
                // descarta um deles por chave duplicada).
                runCatching { idsTensor.close() }
                runCatching { maskTensor.close() }
            }
            val decHidden = hidden[0]
            val h = decHidden[0].size
            val flatHidden = FloatArray(n * h) { i -> decHidden[i / h][i % h] }
            val decInNames = dec.inputNames.toList()
            val decLogitsName = dec.outputNames.first()
            val gen = mutableListOf(decStartId.toLong())
            for (step in 0 until 128) {
                val m = gen.size
                val inputs = mutableMapOf(
                    decInNames[0] to OnnxTensor.createTensor(env, LongBuffer.wrap(gen.toLongArray()), longArrayOf(1, m.toLong())),
                    decInNames[1] to OnnxTensor.createTensor(
                        env, java.nio.FloatBuffer.wrap(flatHidden), longArrayOf(1, n.toLong(), h.toLong())),
                )
                if (decInNames.size > 2) {
                    inputs[decInNames[2]] = OnnxTensor.createTensor(env, LongBuffer.wrap(encMask), longArrayOf(1, n.toLong()))
                }
                val next: Int
                try {
                    dec.run(inputs).use { out ->
                        @Suppress("UNCHECKED_CAST")
                        val logits = out.get(decLogitsName).get() as Array<Array<FloatArray>>
                        val last = logits[0][logits[0].size - 1]
                        var best = 0
                        var bestV = last[0]
                        for (k in 1 until last.size) {
                            if (last[k] > bestV) {
                                bestV = last[k]
                                best = k
                            }
                        }
                        next = best
                    }
                } finally {
                    // Até 128 passos/frase: cada input vazado aqui vira OOM no EP.
                    inputs.values.forEach { runCatching { it.close() } }
                }
                if (next == eosId) break
                gen.add(next.toLong())
            }
            return decode(tok, unk, gen.drop(1).map { it.toInt() }, decStartId, eosId)
        } finally {
            lock.unlock()
        }
    }

    /// Greedy longest-match (▁ marca início de palavra).
    private fun encode(tok: Map<String, Int>, unk: Int, text: String): List<Int> {
        val out = mutableListOf<Int>()
        for (word in text.split(Regex("\\s+"))) {
            if (word.isEmpty()) continue
            var rest = "▁$word"
            while (rest.isNotEmpty()) {
                var hit: Int? = null
                var len = 0
                var l = rest.length
                while (l > 0) {
                    val id = tok[rest.substring(0, l)]
                    if (id != null) {
                        hit = id
                        len = l
                        break
                    }
                    l--
                }
                if (hit != null) {
                    out.add(hit)
                    rest = rest.substring(len)
                } else {
                    out.add(unk)
                    rest = rest.substring(1)
                }
            }
        }
        return out
    }

    private fun decode(tok: Map<String, Int>, unk: Int, ids: List<Int>, bos: Int, eos: Int): String {
        val inv = HashMap<Int, String>(tok.size * 2)
        for ((k, v) in tok) inv.putIfAbsent(v, k)
        val sb = StringBuilder()
        for (id in ids) {
            if (id == bos || id == eos) continue
            val t = inv[id] ?: "<unk>"
            if (t.startsWith("▁")) sb.append(' ').append(t.drop(1)) else sb.append(t)
        }
        return sb.toString().trim().replace(Regex("\\s+([.,!?;:…%)])"), "$1")
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
        encoder = null
        decoder = null
        vocab = null
        loadedDir = null
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/marian"
    }
}
