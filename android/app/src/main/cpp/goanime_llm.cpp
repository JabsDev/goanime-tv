// Ponte JNI fina p/ tradução local via llama.cpp (GGUF, CPU).
// Uma sessão por modelo (load uma vez, reusa entre frases — o load de um
// GGUF de ~1 GB não cabe no caminho por-frase). Geração greedy (temp 0),
// teto 128 tokens novos, para em EOS. Uso single-thread (lock no Kotlin).
// Sem `common/`: só C API (llama.h); template montado no Kotlin.
#include <jni.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include <sched.h>
#include <unistd.h>

#include <android/log.h>

#include "llama.h"

namespace {

struct Handle {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    llama_sampler * sampler = nullptr;
    // Tokens da última chamada: o maior prefixo comum com a próxima é a
    // instrução fixa, cujo KV reaproveitamos (evita re-prefixar a cada fala).
    std::vector<llama_token> last_ids;
};

int n_threads() {
    const unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) return 2;
    return (int) std::min<unsigned>(hw, 4);
}

// big.LITTLE: prende a thread atual (e as threads do ggml, criadas depois no
// init do contexto e que herdam a máscara) nos núcleos de maior `cpuinfo_max_freq`.
// Sem isto, parte das threads cai nos little (A55, ~2x mais lentos) e o decode
// perde pico. Se não houver cpufreq exposto, não faz nada.
void pin_to_fast_cores(int n) {
    struct Core { int id; long khz; };
    std::vector<Core> cores;
    for (int c = 0; c < 32; ++c) {
        std::ifstream f("/sys/devices/system/cpu/cpu" + std::to_string(c) +
                        "/cpufreq/cpuinfo_max_freq");
        long khz = 0;
        if (f.is_open() && (f >> khz) && khz > 0) cores.push_back({c, khz});
    }
    if (cores.empty()) {
        __android_log_print(ANDROID_LOG_WARN, "GoAnimeLLM",
                            "afinidade: sem cpufreq (largando)");
        return;
    }
    std::sort(cores.begin(), cores.end(),
              [](const Core & a, const Core & b) { return a.khz > b.khz; });
    if ((int) cores.size() < n) n = (int) cores.size();
    cpu_set_t set;
    CPU_ZERO(&set);
    for (int i = 0; i < n; ++i) CPU_SET(cores[i].id, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        __android_log_print(ANDROID_LOG_WARN, "GoAnimeLLM",
                            "afinidade: sched_setaffinity falhou errno=%d", errno);
    } else {
        __android_log_print(ANDROID_LOG_INFO, "GoAnimeLLM",
                            "afinidade: preso nos %d núcleos mais rápidos", n);
    }
}

std::string jstr(JNIEnv * env, jstring s) {
    if (!s) return {};
    const char * c = env->GetStringUTFChars(s, nullptr);
    std::string out(c ? c : "");
    if (c) env->ReleaseStringUTFChars(s, c);
    return out;
}

// Qwen3 vem por padrão com modo "thinking" (<think>…</think>): o raciocínio
// estoura o teto de 128 tokens e a tradução real nunca sai (estudo §2.5/H2).
// Remove os blocos ANTES do utf8_clean; truncado sem fechar também cai.
std::string strip_think(const std::string & s) {
    std::string out;
    size_t pos = 0;
    bool removed = false;
    while (true) {
        const size_t open = s.find("<think>", pos);
        if (open == std::string::npos) {
            out.append(s, pos, s.size() - pos);
            break;
        }
        removed = true;
        out.append(s, pos, open - pos);
        const size_t close = s.find("</think>", open);
        if (close == std::string::npos) break; // truncado: nada mais sai
        pos = close + 8;
    }
    if (removed) {
        __android_log_print(ANDROID_LOG_INFO, "GoAnimeLLM",
                            "bloco <think> removido da resposta");
    }
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

// Loop de geração compartilhado (greedy, teto, KV reaproveitado). Recebe o
// PROMPT JÁ FINAL — cru (nativeGenerate) ou com o template de chat aplicado
// (nativeGenerateChat). Devolve o texto gerado, ainda pré-utf8_clean/strip_think.
std::string run_generate(Handle * h, const std::string & text, int cap) {
    const llama_vocab * vocab = llama_model_get_vocab(h->model);
    const llama_token eos = llama_vocab_eos(vocab);
    // Fim de turno (ex.: <|im_end|>): sem parar nele, modelos de chat podem
    // gastar o teto inteiro de tokens em toda fala (runaway).
    const llama_token eot = llama_vocab_eot(vocab);

    const int n_max = (int) text.size() + 64;
    std::vector<llama_token> tmp(n_max);
    const int n = llama_tokenize(vocab, text.c_str(), (int) text.size(),
                                 tmp.data(), n_max, false, true);
    if (n <= 0) return "";
    std::vector<llama_token> ids(tmp.begin(), tmp.begin() + n);
    // BOS SÓ se o prompt ainda não começa com ele: o template de chat (gemma)
    // pode já trazê-lo, e BOS duplicado desalinha o prefill.
    const llama_token bos = llama_vocab_bos(vocab);
    if (llama_vocab_get_add_bos(vocab) && (ids.empty() || ids.front() != bos)) {
        ids.insert(ids.begin(), bos);
    }

    auto t_prompt = std::chrono::steady_clock::now();

    std::string out;
    // Teto do contexto: prompt + geração precisam caber no n_ctx (1024).
    if ((int) ids.size() > 1024 - cap) {
        __android_log_print(ANDROID_LOG_ERROR, "GoAnimeLLM",
                            "prompt longo (%d tokens), truncado", (int) ids.size());
        ids.resize(1024 - cap);
    }

    // Reuso do KV: a instrução fixa (prefixo comum à fala anterior) já está no
    // cache. Removemos do KV só o que vem depois dela e decodificamos apenas o
    // trecho novo (fala + sufixo). Corta a maior parte do prefill por fala.
    const int n_all = (int) ids.size();
    int lcp = 0;
    {
        const int maxc = (int) std::min(h->last_ids.size(), ids.size());
        while (lcp < maxc && h->last_ids[lcp] == ids[lcp]) ++lcp;
    }
    if (lcp >= n_all) lcp = n_all - 1; // precisa decodificar >=1 p/ gerar logits
    llama_memory_t mem = llama_get_memory(h->ctx);
    bool reuse = lcp > 0 && llama_memory_seq_rm(mem, 0, lcp, -1);
    if (!reuse) {
        llama_memory_clear(mem, true);
        lcp = 0;
    }
    const int start = lcp;
    const int m = n_all - start;
    // pos explícito (start..n_all-1): o KV anterior fica em 0..start-1.
    llama_batch pre = llama_batch_init(m > 0 ? m : 1, 0, 1);
    for (int i = 0; i < m; ++i) {
        pre.token[i]     = ids[start + i];
        pre.pos[i]       = start + i;
        pre.n_seq_id[i]  = 1;
        pre.seq_id[i][0] = 0;
        pre.logits[i]    = (i == m - 1) ? 1 : 0;
    }
    pre.n_tokens = m;
    const bool ok = llama_decode(h->ctx, pre) == 0;
    llama_batch_free(pre);
    h->last_ids = ids;
    auto t_prefill = std::chrono::steady_clock::now();
    int gen = 0;
    // 1º token sai dos logits do prefill (batch_get_one marca o último).
    llama_token cur =
        ok ? llama_sampler_sample(h->sampler, h->ctx, -1) : eos;
    while (ok && gen < cap) {
        if (cur == eos || (eot >= 0 && cur == eot)) break;
        char buf[256];
        const int len = llama_token_to_piece(vocab, cur, buf, sizeof(buf), 0, false);
        if (len > 0) out.append(buf, len);
        ++gen;
        if ((int) out.size() > 4096) break;
        // GGUF cujo fim de turno vem como texto literal (não mapeado a eot):
        // corta e para, em vez de gastar o teto inteiro.
        const size_t endpos = out.find("<|im_end|>");
        if (endpos != std::string::npos) { out.resize(endpos); break; }
        // 1 token por vez (KV reutilizado).
        llama_batch cur_batch = llama_batch_get_one(&cur, 1);
        if (llama_decode(h->ctx, cur_batch) != 0) break;
        cur = llama_sampler_sample(h->sampler, h->ctx, -1);
    }
    auto t_end = std::chrono::steady_clock::now();
    auto ms = [](std::chrono::steady_clock::time_point a,
                 std::chrono::steady_clock::time_point b) {
        return std::chrono::duration<double, std::milli>(b - a).count();
    };
    const double dec_ms = ms(t_prefill, t_end);
    // Diagnóstico de perf (logcat tag GoAnimeLLMPerf): prova se o teto é o teto
    // (gen==cap → runaway) e a velocidade real (tok_s).
    __android_log_print(
        ANDROID_LOG_INFO, "GoAnimeLLMPerf",
        "prompt=%d reused=%d new=%d gen=%d cap=%d prefill=%.0fms decode=%.0fms tok_s=%.2f",
        (int) ids.size(), start, m, gen, cap, ms(t_prompt, t_prefill), dec_ms,
        dec_ms > 0 ? gen * 1000.0 / dec_ms : 0.0);
    return out;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_example_goanime_1tv_LlmBridge_nativeLoad(JNIEnv * env, jobject, jstring modelPath) {
    const std::string path = jstr(env, modelPath);
    // Antes de criar modelo/contexto: as threads do ggml herdam esta máscara.
    pin_to_fast_cores(n_threads());
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
    const int cap = maxTokens > 0 ? (int) maxTokens : 128;
    const std::string out = run_generate(h, text, cap);
    return env->NewStringUTF(utf8_clean(strip_think(out)).c_str());
}

// Igual ao nativeGenerate, mas aplica o TEMPLATE DE CHAT embutido no GGUF
// (ex.: gemma-3 <start_of_turn>) em vez de receber o prompt cru. Sem template,
// um modelo "Thinking" não reconhece o fim do turno e continua o texto até
// estourar o teto (runaway de ~11 min/cue medido no EP3 com o Heretic).
JNIEXPORT jstring JNICALL
Java_com_example_goanime_1tv_LlmBridge_nativeGenerateChat(
        JNIEnv * env, jobject, jlong ptr, jstring prompt, jint maxTokens) {
    auto * h = reinterpret_cast<Handle *>(ptr);
    if (!h || !h->model || !h->ctx || !h->sampler) return nullptr;
    const std::string raw = jstr(env, prompt);
    if (raw.empty()) return env->NewStringUTF("");

    std::string text = raw;
    const char * tmpl = llama_model_chat_template(h->model, nullptr);
    if (tmpl) {
        __android_log_print(ANDROID_LOG_INFO, "GoAnimeLLM",
                            "chat_template embutido: %.90s", tmpl);
        const llama_chat_message msg{"user", raw.c_str()};
        std::vector<char> buf(2 * raw.size() + 4096);
        int need = llama_chat_apply_template(tmpl, &msg, 1, true,
                                             buf.data(), (int) buf.size());
        if (need > (int) buf.size()) {  // buffer curto: realoca e repete
            buf.resize(need + 1);
            need = llama_chat_apply_template(tmpl, &msg, 1, true,
                                             buf.data(), (int) buf.size());
        }
        if (need > 0) {
            text.assign(buf.data(), need);
            __android_log_print(ANDROID_LOG_INFO, "GoAnimeLLM",
                                "chat template aplicado (%d chars)", need);
        } else {
            __android_log_print(ANDROID_LOG_WARN, "GoAnimeLLM",
                                "chat_apply_template devolveu %d; prompt cru", need);
        }
    } else {
        __android_log_print(ANDROID_LOG_WARN, "GoAnimeLLM",
                            "GGUF sem chat template embutido; prompt cru");
    }

    const int cap = maxTokens > 0 ? (int) maxTokens : 128;
    const std::string out = run_generate(h, text, cap);
    return env->NewStringUTF(utf8_clean(strip_think(out)).c_str());
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
