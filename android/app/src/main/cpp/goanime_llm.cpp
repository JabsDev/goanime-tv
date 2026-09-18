// Ponte JNI fina p/ tradução local via llama.cpp (GGUF, CPU).
// Uma sessão por modelo (load uma vez, reusa entre frases — o load de um
// GGUF de ~1 GB não cabe no caminho por-frase). Geração greedy (temp 0),
// teto 128 tokens novos, para em EOS. Uso single-thread (lock no Kotlin).
// Sem `common/`: só C API (llama.h); template montado no Kotlin.
#include <jni.h>

#include <algorithm>
#include <string>
#include <thread>
#include <vector>

#include <android/log.h>

#include "llama.h"

namespace {

struct Handle {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    llama_sampler * sampler = nullptr;
};

int n_threads() {
    const unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) return 2;
    return (int) std::min<unsigned>(hw, 4);
}

std::string jstr(JNIEnv * env, jstring s) {
    if (!s) return {};
    const char * c = env->GetStringUTFChars(s, nullptr);
    std::string out(c ? c : "");
    if (c) env->ReleaseStringUTFChars(s, c);
    return out;
}

// NewStringUTF com byte inválido = ART aborta a VM (morte sem exceção).
// O teto de 128 tokens pode partir um char multibyte (japonês!) bem no
// fim — e o crash caía na 1ª frase com breadcrumb de "carregamento".
// Limpa a cauda partida e troca byte inválido por U+FFFD antes do JNI.
std::string utf8_clean(const std::string & s) {
    std::string o;
    o.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        const unsigned char c = s[i];
        size_t len = 1;
        if ((c & 0x80) == 0x00) len = 1;
        else if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        else { o.append("\xEF\xBF\xBD"); ++i; continue; }
        if (i + len > s.size()) break;  // cauda partida: descarta
        bool ok = true;
        for (size_t k = 1; k < len; ++k) {
            if ((s[i + k] & 0xC0) != 0x80) { ok = false; break; }
        }
        if (!ok) { o.append("\xEF\xBF\xBD"); ++i; continue; }
        o.append(s, i, len);
        i += len;
    }
    return o;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_example_goanime_1tv_LlmBridge_nativeLoad(JNIEnv * env, jobject, jstring modelPath) {
    const std::string path = jstr(env, modelPath);
    llama_model_params mparams = llama_model_default_params();
    llama_model * model = llama_model_load_from_file(path.c_str(), mparams);
    // 0 = arquivo inexistente/truncado; -1 = sem RAM p/ contexto.
    // O Kotlin converte em LLM_CORRUPT / LLM_OOM (mensagem PT-BR no Dart).
    if (!model) {
        __android_log_print(ANDROID_LOG_ERROR, "GoAnimeLLM",
                            "model_open falhou: %s", path.c_str());
        return 0;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = 1024;  // cues curtas; KV pequeno (RAM de TV). 2048 tomava
    // LMK-kill em stick fraco no pico STT-residual + MT — 1024 corta o KV
    // quase à metade sem afetar frase a frase (teto 128 tokens novos).
    // KV em Q8_0 em vez do padrão F16: metade da RAM de novo, perda
    // irrelevante p/ frase curta (só os 2 campos, resto nem percebe).
    cparams.type_k = GGML_TYPE_Q8_0;
    cparams.type_v = GGML_TYPE_Q8_0;
    cparams.n_threads = n_threads();
    cparams.n_threads_batch = n_threads();
    llama_context * ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        __android_log_print(ANDROID_LOG_ERROR, "GoAnimeLLM",
                            "ctx_init falhou (OOM?): %s", path.c_str());
        return -1;
    }

    auto * h = new Handle{model, ctx, nullptr};
    auto schain = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(schain, llama_sampler_init_temp(0.0f));  // greedy
    // Anti-runaway ("lalala…", "!!!!…"): cue patológica do STT (música/efeito
    // alucinado) entrava em loop até o teto de 128 tokens e virava legenda.
    // repeat 1.18 nas últimas 64: não muda tradução normal (já medida no
    // gate), só quebra o ciclo degenerado. freq/present zerados (greedy).
    const llama_vocab * v = llama_model_get_vocab(model);
    llama_sampler_chain_add(schain, llama_sampler_init_penalties(
        llama_vocab_n_tokens(v), 64, 1.18f, 0.0f, 0.0f));
    llama_sampler_chain_add(schain, llama_sampler_init_dist(0));
    h->sampler = schain;
    return reinterpret_cast<jlong>(h);
}

JNIEXPORT jstring JNICALL
Java_com_example_goanime_1tv_LlmBridge_nativeGenerate(
        JNIEnv * env, jobject, jlong ptr, jstring prompt, jint maxTokens) {
    auto * h = reinterpret_cast<Handle *>(ptr);
    if (!h || !h->model || !h->ctx || !h->sampler) return nullptr;
    const std::string text = jstr(env, prompt);
    if (text.empty()) return env->NewStringUTF("");

    const llama_vocab * vocab = llama_model_get_vocab(h->model);
    const llama_token eos = llama_vocab_eos(vocab);

    // Tokeniza com specials (prompt contém <|im_start|> etc. literais) e
    // prefixa BOS como o template Jinja do modelo (igual ao spike validado).
    const int n_max = (int) text.size() + 64;
    std::vector<llama_token> tmp(n_max);
    const int n = llama_tokenize(vocab, text.c_str(), (int) text.size(),
                                 tmp.data(), n_max, false, true);
    if (n <= 0) return env->NewStringUTF("");
    std::vector<llama_token> ids;
    ids.reserve(n + 1);
    ids.push_back(llama_vocab_bos(vocab));
    ids.insert(ids.end(), tmp.begin(), tmp.begin() + n);

    llama_memory_clear(llama_get_memory(h->ctx), true);

    std::string out;
    const int cap = maxTokens > 0 ? (int) maxTokens : 128;
    // Teto do contexto: prompt + geração precisam caber no n_ctx (1024).
    // Sem isto, cue patológica (alucinação longa do STT) estourava o KV.
    if ((int) ids.size() > 1024 - cap) {
        __android_log_print(ANDROID_LOG_ERROR, "GoAnimeLLM",
                            "prompt longo (%d tokens), truncado", (int) ids.size());
        ids.resize(1024 - cap);
    }
    // Prefill em pedaços de 512: batch único maior que n_batch =
    // GGML_ASSERT em llama_decode → SIGABRT sem exceção (app "só fecha",
    // visto no EP3). Padrão dos clientes llama.cpp; KV acumula igual.
    bool ok = true;
    for (size_t off = 0; off < ids.size(); off += 512) {
        const size_t chunk = std::min<size_t>(512, ids.size() - off);
        llama_batch pre = llama_batch_get_one(ids.data() + off, (int) chunk);
        if (llama_decode(h->ctx, pre) != 0) { ok = false; break; }
    }
    int gen = 0;
    // 1º token sai dos logits do prefill (batch_get_one marca o último).
    llama_token cur =
        ok ? llama_sampler_sample(h->sampler, h->ctx, -1) : eos;
    while (ok && gen < cap) {
        if (cur == eos) break;
        char buf[256];
        const int len = llama_token_to_piece(vocab, cur, buf, sizeof(buf), 0, false);
        if (len > 0) out.append(buf, len);
        ++gen;
        if ((int) out.size() > 4096) break;
        // 1 token por vez (KV reutilizado).
        llama_batch cur_batch = llama_batch_get_one(&cur, 1);
        if (llama_decode(h->ctx, cur_batch) != 0) break;
        cur = llama_sampler_sample(h->sampler, h->ctx, -1);
    }
    return env->NewStringUTF(utf8_clean(out).c_str());
}

JNIEXPORT void JNICALL
Java_com_example_goanime_1tv_LlmBridge_nativeFree(JNIEnv *, jobject, jlong ptr) {
    auto * h = reinterpret_cast<Handle *>(ptr);
    if (!h) return;
    if (h->sampler) llama_sampler_free(h->sampler);
    if (h->ctx) llama_free(h->ctx);
    if (h->model) llama_model_free(h->model);
    delete h;
}

}  // extern "C"
