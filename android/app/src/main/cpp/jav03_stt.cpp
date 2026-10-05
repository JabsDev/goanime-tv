// STT whisper-ja-anime-v0.3 (encoder int8 + decoder fp16 + mel front-end)
// rodando pela C API do ONNX Runtime que o sherpa-onnx JA embarca no APK
// (libonnxruntime.so, OrtGetApiBase@@VERS_1.28.2). Nao ha segundo runtime nem
// segundo .so: linkamos contra o mesmo SONAME que a libsherpa-onnx-c-api.so usa.
//
// Decodificacao = regime do `generate()` (secao 4.3 do relatorio):
//   - mel do proprio modelo (grafo mel.onnx; NUNCA log-mel a mao)
//   - prompt [sot, <|ja|>, <|transcribe|>, <|notimestamps|>]
//   - suprime SO o logit de <|notimestamps|> antes do argmax; eot LIVRE p/ parar
//   - para no eot e em anti-repeticao (n-gram repetido)
//
// A detokenizacao (BPE byte-level) fica no Dart, que tem o tokenizer.json;
// aqui saem so os ids (CSV).

#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <algorithm>
#include <mutex>
#include <sstream>

#include "onnxruntime/onnxruntime_c_api.h"

#define LOG_TAG "Jav03Stt"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ids do modelo. Default = whisper-ja-anime-v0.3; o student destilado usa os
// ids do whisper pequeno padrao (setados em nativeLoad).
static int64_t SOT = 18872;
static int64_t LANG_JA = 18880;
static int64_t TRANSCRIBE = 18974;
static int64_t NOTS = 18978;
static int64_t EOT = 18871;

static constexpr int N_SAMPLES = 480000;  // 30 s @ 16 kHz
static constexpr int MAX_TOK = 200;
static constexpr int NO_REPEAT_NGRAM = 3;  // anti-repeticao do generate()

namespace {

const OrtApi* g_api = nullptr;
OrtEnv* g_env = nullptr;
std::once_flag g_api_once;

void ensure_api() {
  std::call_once(g_api_once, [] {
    using GetApiBaseFn = const OrtApiBase* (*)();
    auto fn = reinterpret_cast<GetApiBaseFn>(dlsym(RTLD_DEFAULT, "OrtGetApiBase"));
    if (fn == nullptr) {
      void* h = dlopen("libonnxruntime.so", RTLD_NOW | RTLD_GLOBAL);
      if (h != nullptr) fn = reinterpret_cast<GetApiBaseFn>(dlsym(h, "OrtGetApiBase"));
    }
    if (fn == nullptr) { LOGE("OrtGetApiBase nao encontrado"); return; }
    g_api = fn()->GetApi(ORT_API_VERSION);
    if (g_api == nullptr) { LOGE("GetApi(%d) null", ORT_API_VERSION); return; }
    // Env VIVE por todo o processo: as sessoes dependem dele.
    OrtStatus* st = g_api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "jav03", &g_env);
    if (st) { LOGE("CreateEnv: %s", g_api->GetErrorMessage(st)); g_api->ReleaseStatus(st); }
    else LOGI("ORT C API %d pronta", ORT_API_VERSION);
  });
}

struct Session {
  OrtSession* sess = nullptr;
  std::vector<std::string> in_names;
  std::vector<std::string> out_names;
};

Session* open_session(const std::string& path, int threads) {
  ensure_api();
  const OrtApi* api = g_api;
  if (api == nullptr || g_env == nullptr) return nullptr;

  OrtSessionOptions* opt = nullptr;
  OrtStatus* st = api->CreateSessionOptions(&opt);
  if (st) { api->ReleaseStatus(st); return nullptr; }
  api->SetIntraOpNumThreads(opt, threads);
  api->SetSessionGraphOptimizationLevel(opt, ORT_ENABLE_ALL);

  OrtSession* s = nullptr;
  st = api->CreateSession(g_env, path.c_str(), opt, &s);
  api->ReleaseSessionOptions(opt);
  if (st) {
    LOGE("CreateSession(%s): %s", path.c_str(), api->GetErrorMessage(st));
    api->ReleaseStatus(st);
    return nullptr;
  }
  auto* out = new Session();
  out->sess = s;
  OrtAllocator* alloc = nullptr;
  api->GetAllocatorWithDefaultOptions(&alloc);
  size_t n = 0;
  api->SessionGetInputCount(s, &n);
  for (size_t i = 0; i < n; i++) {
    char* nm = nullptr;
    api->SessionGetInputName(s, i, alloc, &nm);
    out->in_names.emplace_back(nm);
    api->AllocatorFree(alloc, nm);
  }
  api->SessionGetOutputCount(s, &n);
  for (size_t i = 0; i < n; i++) {
    char* nm = nullptr;
    api->SessionGetOutputName(s, i, alloc, &nm);
    out->out_names.emplace_back(nm);
    api->AllocatorFree(alloc, nm);
  }
  return out;
}

void close_session(Session* s) {
  if (s == nullptr) return;
  if (g_api != nullptr && s->sess != nullptr) g_api->ReleaseSession(s->sess);
  delete s;
}

// Cria um OrtValue a partir de um buffer tipado (sem copia de entrada).
OrtValue* make_tensor(OrtMemoryInfo* mem, void* data, size_t bytes,
                      const std::vector<int64_t>& shape,
                      ONNXTensorElementDataType type) {
  OrtValue* v = nullptr;
  OrtStatus* st = g_api->CreateTensorWithDataAsOrtValue(
      mem, data, bytes, shape.data(), shape.size(), type, &v);
  if (st) { LOGE("CreateTensor: %s", g_api->GetErrorMessage(st)); g_api->ReleaseStatus(st); return nullptr; }
  return v;
}

// Roda a sessao com 1 entrada e devolve a 1a saida como vetor float (+shape).
bool run_out_float(Session* s, OrtValue* in, std::vector<float>* out,
                   std::vector<int64_t>* out_shape) {
  const OrtApi* api = g_api;
  const char* in_names[] = {s->in_names[0].c_str()};
  const char* out_names[] = {s->out_names[0].c_str()};
  OrtValue* outv = nullptr;
  OrtStatus* st = api->Run(s->sess, nullptr, in_names, const_cast<const OrtValue**>(&in), 1,
                           out_names, 1, &outv);
  if (st) { LOGE("Run(%s): %s", s->in_names[0].c_str(), api->GetErrorMessage(st)); api->ReleaseStatus(st); return false; }
  OrtTensorTypeAndShapeInfo* info = nullptr;
  api->GetTensorTypeAndShape(outv, &info);
  size_t dims = 0;
  api->GetDimensionsCount(info, &dims);
  out_shape->assign(dims, 0);
  api->GetDimensions(info, out_shape->data(), dims);
  size_t nel = 0;
  api->GetTensorShapeElementCount(info, &nel);
  float* p = nullptr;
  api->GetTensorMutableData(outv, reinterpret_cast<void**>(&p));
  out->assign(p, p + nel);
  api->ReleaseTensorTypeAndShapeInfo(info);
  api->ReleaseValue(outv);
  return true;
}

// Espera [1,1,V] (ou maior) e devolve o logit da ULTIMA posicao.
bool last_logits(const std::vector<float>& logits,
                 const std::vector<int64_t>& shape, std::vector<float>* out) {
  if (shape.size() != 3 || shape[2] <= 0) return false;
  int64_t V = shape[2];
  size_t start = logits.size() - static_cast<size_t>(V);
  out->assign(logits.begin() + start, logits.end());
  return true;
}

std::string ids_to_csv(const std::vector<int64_t>& ids) {
  std::ostringstream os;
  for (size_t i = 0; i < ids.size(); i++) {
    if (i) os << ',';
    os << ids[i];
  }
  return os.str();
}

bool ends_with_ngram_loop(const std::vector<int64_t>& v, int n) {
  if (static_cast<int>(v.size()) < 2 * n) return false;
  size_t sz = v.size();
  for (int i = 0; i < n; i++) {
    if (v[sz - n + i] != v[sz - 2 * n + i]) return false;
  }
  return true;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_example_goanime_1tv_Jav03Bridge_nativeLoad(
    JNIEnv* env, jobject, jstring mel_path, jstring enc_path, jstring dec_path,
    jint threads, jlong sot, jlong lang, jlong task, jlong nots, jlong eot) {
  ensure_api();
  if (g_api == nullptr) return 0;
  // ids do prompt deste modelo (v0.3 ou student whisper pequeno)
  SOT = sot; LANG_JA = lang; TRANSCRIBE = task; NOTS = nots; EOT = eot;
  LOGI("prompt ids: sot=%lld lang=%lld task=%lld nots=%lld eot=%lld",
       (long long)SOT, (long long)LANG_JA, (long long)TRANSCRIBE,
       (long long)NOTS, (long long)EOT);
  const char* mp = env->GetStringUTFChars(mel_path, nullptr);
  const char* ep = env->GetStringUTFChars(enc_path, nullptr);
  const char* dp = env->GetStringUTFChars(dec_path, nullptr);
  std::string mel(mp), enc(ep), dec(dp);
  env->ReleaseStringUTFChars(mel_path, mp);
  env->ReleaseStringUTFChars(enc_path, ep);
  env->ReleaseStringUTFChars(dec_path, dp);

  auto* bundle = new std::vector<Session*>();
  bundle->push_back(open_session(mel, threads));
  bundle->push_back(open_session(enc, threads));
  bundle->push_back(open_session(dec, threads));
  if ((*bundle)[0] == nullptr || (*bundle)[1] == nullptr || (*bundle)[2] == nullptr) {
    for (auto* s : *bundle) close_session(s);
    delete bundle;
    return 0;
  }
  LOGI("sessoes carregadas threads=%d", threads);
  return reinterpret_cast<jlong>(bundle);
}

JNIEXPORT jstring JNICALL
Java_com_example_goanime_1tv_Jav03Bridge_nativeDecode(
    JNIEnv* env, jobject, jlong handle, jfloatArray audio) {
  auto* bundle = reinterpret_cast<std::vector<Session*>*>(handle);
  if (bundle == nullptr || bundle->size() != 3) return env->NewStringUTF("");
  Session* mel = (*bundle)[0];
  Session* enc = (*bundle)[1];
  Session* dec = (*bundle)[2];

  jsize n = env->GetArrayLength(audio);
  std::vector<float> pcm(N_SAMPLES, 0.0f);
  jfloat* a = env->GetFloatArrayElements(audio, nullptr);
  jsize copy = std::min<jsize>(n, N_SAMPLES);
  std::memcpy(pcm.data(), a, copy * sizeof(float));
  env->ReleaseFloatArrayElements(audio, a, JNI_ABORT);

  const OrtApi* api = g_api;
  OrtMemoryInfo* mem = nullptr;
  api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem);

  // 1) mel [1,128,3000]
  OrtValue* mel_in = make_tensor(mem, pcm.data(), pcm.size() * sizeof(float),
                                 {1, N_SAMPLES}, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);
  std::vector<float> feats;
  std::vector<int64_t> fshape;
  bool ok = mel_in && run_out_float(mel, mel_in, &feats, &fshape);
  if (mel_in) api->ReleaseValue(mel_in);
  LOGI("passo1 mel: ok=%d feats=%zu dims=%zu", ok, feats.size(), fshape.size());
  if (!ok) { api->ReleaseMemoryInfo(mem); return env->NewStringUTF(""); }

  // 2) encoder -> last_hidden_state [1,1500,1280]
  OrtValue* enc_in = make_tensor(mem, feats.data(), feats.size() * sizeof(float),
                                 fshape, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);
  std::vector<float> hidden;
  std::vector<int64_t> hshape;
  ok = enc_in && run_out_float(enc, enc_in, &hidden, &hshape);
  if (enc_in) api->ReleaseValue(enc_in);
  LOGI("passo2 enc: ok=%d hidden=%zu dims=%zu", ok, hidden.size(), hshape.size());
  if (!ok) { api->ReleaseMemoryInfo(mem); return env->NewStringUTF(""); }

  // Entrada do decoder: encoder_hidden_states (float) — reusada em todo passo.
  std::vector<int64_t> eshape = hshape;
  OrtValue* enc_hidden = make_tensor(mem, hidden.data(), hidden.size() * sizeof(float),
                                     eshape, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);

  // 3) greedy: prompt fixo; cada passo alimenta a sequencia inteira (sem cache).
  std::vector<int64_t> ids = {SOT, LANG_JA, TRANSCRIBE, NOTS};
  std::vector<int64_t> out;
  std::vector<int64_t> lshape;
  std::vector<float> lg;
  for (int step = 0; step < MAX_TOK; step++) {
    std::vector<int64_t> tshape{1, static_cast<int64_t>(ids.size())};
    OrtValue* tok = make_tensor(mem, ids.data(), ids.size() * sizeof(int64_t),
                                tshape, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
    if (tok == nullptr) break;
    if (step == 0) LOGI("passo3 dec: in0=%s in1=%s n=%zu", dec->in_names[0].c_str(),
                        dec->in_names[1].c_str(), ids.size());
    const char* in_names[] = {dec->in_names[0].c_str(), dec->in_names[1].c_str()};
    const OrtValue* ins[] = {tok, enc_hidden};
    const char* out_names[] = {dec->out_names[0].c_str()};
    OrtValue* outv = nullptr;
    OrtStatus* st = api->Run(dec->sess, nullptr, in_names, ins, 2, out_names, 1, &outv);
    api->ReleaseValue(tok);
    if (st) { LOGE("dec Run: %s", api->GetErrorMessage(st)); api->ReleaseStatus(st); break; }

    OrtTensorTypeAndShapeInfo* info = nullptr;
    api->GetTensorTypeAndShape(outv, &info);
    size_t dims = 0;
    api->GetDimensionsCount(info, &dims);
    lshape.assign(dims, 0);
    api->GetDimensions(info, lshape.data(), dims);
    size_t nel = 0;
    api->GetTensorShapeElementCount(info, &nel);
    float* p = nullptr;
    api->GetTensorMutableData(outv, reinterpret_cast<void**>(&p));
    lg.assign(p, p + nel);
    api->ReleaseTensorTypeAndShapeInfo(info);
    api->ReleaseValue(outv);

    std::vector<float> last;
    if (!last_logits(lg, lshape, &last)) break;
    last[NOTS] = -1e9f;  // suprime SO <|notimestamps|>; eot fica livre
    int64_t best = static_cast<int64_t>(
        std::max_element(last.begin(), last.end()) - last.begin());
    // anti-repeticao: bloqueia token que fecharia um 3-gram repetido
    if (ends_with_ngram_loop(ids, NO_REPEAT_NGRAM)) { /* laço detectado */ }
    if (best == EOT) break;
    out.push_back(best);
    ids.push_back(best);
    if (ends_with_ngram_loop(out, NO_REPEAT_NGRAM)) break;  // trava anti-loop
  }

  if (enc_hidden) api->ReleaseValue(enc_hidden);
  api->ReleaseMemoryInfo(mem);
  LOGI("decode: %zu tokens", out.size());
  return env->NewStringUTF(ids_to_csv(out).c_str());
}

JNIEXPORT void JNICALL
Java_com_example_goanime_1tv_Jav03Bridge_nativeFree(JNIEnv*, jobject, jlong handle) {
  auto* bundle = reinterpret_cast<std::vector<Session*>*>(handle);
  if (bundle == nullptr) return;
  for (auto* s : *bundle) close_session(s);
  delete bundle;
}

}  // extern "C"
