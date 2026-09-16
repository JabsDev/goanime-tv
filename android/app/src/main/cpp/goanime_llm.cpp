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
    cparams.n_ctx = 2048;  // cues curtas; KV pequeno (RAM de TV)
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
    int gen = 0;
    bool first = true;
    llama_token cur = -1;
    while (gen < cap) {
        // Prefill na 1ª iteração; depois 1 token por vez (KV reutilizado).
        llama_batch cur_batch = first
            ? llama_batch_get_one(ids.data(), (int) ids.size())
            : llama_batch_get_one(&cur, 1);
        first = false;
        if (llama_decode(h->ctx, cur_batch) != 0) break;
        cur = llama_sampler_sample(h->sampler, h->ctx, -1);
        if (cur == eos) break;
        char buf[256];
        const int len = llama_token_to_piece(vocab, cur, buf, sizeof(buf), 0, false);
        if (len > 0) out.append(buf, len);
        ++gen;
        if ((int) out.size() > 4096) break;
    }
    return env->NewStringUTF(out.c_str());
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
