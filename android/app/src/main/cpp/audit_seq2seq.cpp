// Auditor JA seq2seq (ByT5 fine-tunado) sobre o ONNX Runtime que o
// sherpa-onnx JA embarca no APK (mesmo libonnxruntime.so do jav03_stt.cpp).
//
// ByT5 e byte-level: NAO ha tokenizer no runtime. Codificar = cada byte UTF-8
// vira id = byte + 3, mais EOS(1) no fim. Decodificar = id-3 vira byte, para em
// EOS(1). (Validado contra o tokenizer do HF: "ば化け" -> [230,132,179,...,1].)
//
// Dois grafos: encoder(ids,mask)->hidden ; decoder(dec_ids,hidden,enc_mask)
// ->logits. Sem KV cache (legenda curta): cada passo realimenta a sequencia
// inteira e pega o argmax da ultima posicao.

#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <mutex>

#include "onnxruntime/onnxruntime_c_api.h"

#define LOG_TAG "AuditSeq2Seq"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static constexpr int64_t PAD_ID = 0;
static constexpr int64_t EOS_ID = 1;
static constexpr int64_t BYTE_OFFSET = 3;   // id = byte + 3
static constexpr int64_t BYTE_MAX_ID = 258; // 255 + 3
static constexpr int MAX_NEW = 256;

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
    OrtStatus* st = g_api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "audit", &g_env);
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
  if (st) { LOGE("CreateSession(%s): %s", path.c_str(), api->GetErrorMessage(st)); api->ReleaseStatus(st); return nullptr; }
  auto* out = new Session();
  out->sess = s;
  OrtAllocator* alloc = nullptr;
  api->GetAllocatorWithDefaultOptions(&alloc);
  size_t n = 0;
  api->SessionGetInputCount(s, &n);
  for (size_t i = 0; i < n; i++) {
    char* nm = nullptr; api->SessionGetInputName(s, i, alloc, &nm);
    out->in_names.emplace_back(nm); api->AllocatorFree(alloc, nm);
  }
  api->SessionGetOutputCount(s, &n);
  for (size_t i = 0; i < n; i++) {
    char* nm = nullptr; api->SessionGetOutputName(s, i, alloc, &nm);
    out->out_names.emplace_back(nm); api->AllocatorFree(alloc, nm);
  }
  return out;
}

void close_session(Session* s) {
  if (s == nullptr) return;
  if (g_api != nullptr && s->sess != nullptr) g_api->ReleaseSession(s->sess);
  delete s;
}

// NewStringUTF exige Modified UTF-8: byte 0xff orfao/0x00 fazem o ART ABORTAR
// a VM (SIGABRT). Modelo treinado sai em UTF-8 valido, mas um modelo ruim (ou
// um caso patologico) pode cuspir bytes soltos — sanitiza e troca por U+FFFD.
std::string utf8_clean(const std::string& s) {
  std::string o;
  o.reserve(s.size());
  for (size_t i = 0; i < s.size();) {
    const unsigned char c = static_cast<unsigned char>(s[i]);
    if (c == 0x00) { o.append("\xEF\xBF\xBD"); ++i; continue; }
    size_t len = 1;
    if ((c & 0x80) == 0x00) len = 1;
    else if ((c & 0xE0) == 0xC0) len = 2;
    else if ((c & 0xF0) == 0xE0) len = 3;
    else if ((c & 0xF8) == 0xF0) len = 4;
    else { o.append("\xEF\xBF\xBD"); ++i; continue; }
    if (i + len > s.size()) break;
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

OrtValue* make_tensor(OrtMemoryInfo* mem, void* data, size_t bytes,
                      const std::vector<int64_t>& shape,
                      ONNXTensorElementDataType type) {
  OrtValue* v = nullptr;
  OrtStatus* st = g_api->CreateTensorWithDataAsOrtValue(
      mem, data, bytes, shape.data(), shape.size(), type, &v);
  if (st) { LOGE("CreateTensor: %s", g_api->GetErrorMessage(st)); g_api->ReleaseStatus(st); return nullptr; }
  return v;
}

// Roda a sessao com N entradas e devolve a 1a saida como float (+shape).
bool run_session(Session* s, const char** in_names, const OrtValue** ins,
                 int n_in, std::vector<float>* out, std::vector<int64_t>* shape) {
  const OrtApi* api = g_api;
  const char* out_names[] = {s->out_names[0].c_str()};
  OrtValue* outv = nullptr;
  OrtStatus* st = api->Run(s->sess, nullptr, in_names, ins, n_in, out_names, 1, &outv);
  if (st) { LOGE("Run(%s): %s", s->in_names[0].c_str(), api->GetErrorMessage(st)); api->ReleaseStatus(st); return false; }
  OrtTensorTypeAndShapeInfo* info = nullptr;
  api->GetTensorTypeAndShape(outv, &info);
  size_t dims = 0;
  api->GetDimensionsCount(info, &dims);
  shape->assign(dims, 0);
  api->GetDimensions(info, shape->data(), dims);
  size_t nel = 0;
  api->GetTensorShapeElementCount(info, &nel);
  float* p = nullptr;
  api->GetTensorMutableData(outv, reinterpret_cast<void**>(&p));
  out->assign(p, p + nel);
  api->ReleaseTensorTypeAndShapeInfo(info);
  api->ReleaseValue(outv);
  return true;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_example_goanime_1tv_Seq2SeqBridge_nativeLoad(
    JNIEnv* env, jobject, jstring enc_path, jstring dec_path, jint threads) {
  ensure_api();
  if (g_api == nullptr) return 0;
  const char* ep = env->GetStringUTFChars(enc_path, nullptr);
  const char* dp = env->GetStringUTFChars(dec_path, nullptr);
  std::string enc(ep), dec(dp);
  env->ReleaseStringUTFChars(enc_path, ep);
  env->ReleaseStringUTFChars(dec_path, dp);

  auto* bundle = new std::vector<Session*>();
  bundle->push_back(open_session(enc, threads));
  bundle->push_back(open_session(dec, threads));
  if ((*bundle)[0] == nullptr || (*bundle)[1] == nullptr) {
    for (auto* s : *bundle) close_session(s);
    delete bundle;
    return 0;
  }
  LOGI("sessoes carregadas threads=%d", threads);
  return reinterpret_cast<jlong>(bundle);
}

JNIEXPORT jstring JNICALL
Java_com_example_goanime_1tv_Seq2SeqBridge_nativeFix(
    JNIEnv* env, jobject, jlong handle, jstring text) {
  auto* bundle = reinterpret_cast<std::vector<Session*>*>(handle);
  if (bundle == nullptr || bundle->size() != 2) return env->NewStringUTF("");
  Session* enc = (*bundle)[0];
  Session* dec = (*bundle)[1];

  const char* tp = env->GetStringUTFChars(text, nullptr);
  std::string src(tp ? tp : "");
  if (tp) env->ReleaseStringUTFChars(text, tp);
  if (src.empty()) return env->NewStringUTF("");

  const OrtApi* api = g_api;
  OrtMemoryInfo* mem = nullptr;
  api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem);

  // 1) tokeniza byte-level: id = byte + 3, + EOS
  std::vector<int64_t> ids;
  ids.reserve(src.size() + 1);
  for (unsigned char c : src) ids.push_back(static_cast<int64_t>(c) + BYTE_OFFSET);
  ids.push_back(EOS_ID);
  std::vector<int64_t> mask(ids.size(), 1);

  // 2) encoder
  std::vector<int64_t> eshape{1, static_cast<int64_t>(ids.size())};
  OrtValue* enc_ids = make_tensor(mem, ids.data(), ids.size() * sizeof(int64_t), eshape, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
  OrtValue* enc_mask = make_tensor(mem, mask.data(), mask.size() * sizeof(int64_t), eshape, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
  std::vector<float> hidden;
  std::vector<int64_t> hshape;
  const char* enc_in[] = {enc->in_names[0].c_str(), enc->in_names[1].c_str()};
  const OrtValue* enc_ins[] = {enc_ids, enc_mask};
  bool ok = enc_ids && enc_mask && run_session(enc, enc_in, enc_ins, 2, &hidden, &hshape);
  if (enc_ids) api->ReleaseValue(enc_ids);
  if (!ok) { if (enc_mask) api->ReleaseValue(enc_mask); api->ReleaseMemoryInfo(mem); return env->NewStringUTF(""); }

  // hidden reusado em todo passo do decoder
  OrtValue* enc_hidden = make_tensor(mem, hidden.data(), hidden.size() * sizeof(float), hshape, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);

  // Teto de saida: um corretor nao estica a linha. Se passar de (entrada + 16)
  // e porque o modelo degenerou num laco (ex.: "ああっ、ああっ…" na cue curta
  // "んっ、んんっ!" -> 256 tokens, 298s). Corta cedo.
  const int64_t out_cap = std::max<int64_t>((int64_t)src.size() + 16, 32);

  // 3) greedy decoder (sem KV cache): realimenta a sequencia inteira
  std::vector<int64_t> dec_ids = {PAD_ID};
  std::vector<int64_t> out_ids;
  std::vector<float> lg;
  std::vector<int64_t> lshape;
  for (int step = 0; step < MAX_NEW; step++) {
    std::vector<int64_t> dshape{1, static_cast<int64_t>(dec_ids.size())};
    OrtValue* din = make_tensor(mem, dec_ids.data(), dec_ids.size() * sizeof(int64_t), dshape, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
    if (din == nullptr) break;
    const char* din_names[] = {dec->in_names[0].c_str(), dec->in_names[1].c_str(), dec->in_names[2].c_str()};
    const OrtValue* dins[] = {din, enc_hidden, enc_mask};
    const char* dout_names[] = {dec->out_names[0].c_str()};
    OrtValue* outv = nullptr;
    OrtStatus* st = api->Run(dec->sess, nullptr, din_names, dins, 3, dout_names, 1, &outv);
    api->ReleaseValue(din);
    if (st) { LOGE("dec Run: %s", api->GetErrorMessage(st)); api->ReleaseStatus(st); break; }
    OrtTensorTypeAndShapeInfo* info = nullptr;
    api->GetTensorTypeAndShape(outv, &info);
    size_t nd = 0; api->GetDimensionsCount(info, &nd);
    lshape.assign(nd, 0); api->GetDimensions(info, lshape.data(), nd);
    size_t nel = 0; api->GetTensorShapeElementCount(info, &nel);
    float* p = nullptr; api->GetTensorMutableData(outv, reinterpret_cast<void**>(&p));
    lg.assign(p, p + nel);
    api->ReleaseTensorTypeAndShapeInfo(info);
    api->ReleaseValue(outv);
    if (lshape.size() != 3 || lshape[2] <= 0) break;
    int64_t V = lshape[2];
    const float* last = lg.data() + lg.size() - static_cast<size_t>(V);
    int64_t best = static_cast<int64_t>(std::max_element(last, last + V) - last);
    if (best == EOS_ID) break;
    out_ids.push_back(best);
    dec_ids.push_back(best);
    if ((int64_t)out_ids.size() >= out_cap) {
      LOGI("anti-runaway: teto de saida (%lld)", (long long)out_cap);
      break;
    }
  }

  if (enc_hidden) api->ReleaseValue(enc_hidden);
  api->ReleaseValue(enc_mask);
  api->ReleaseMemoryInfo(mem);

  // 4) detokeniza: id-3 vira byte (ignora especiais/extra_ids)
  std::string res;
  res.reserve(out_ids.size());
  for (int64_t id : out_ids) {
    if (id >= BYTE_OFFSET && id <= BYTE_MAX_ID) res.push_back(static_cast<char>(id - BYTE_OFFSET));
  }
  LOGI("fix: in=%zu bytes out=%zu ids -> %zu bytes", src.size(), out_ids.size(), res.size());
  return env->NewStringUTF(utf8_clean(res).c_str());
}

JNIEXPORT void JNICALL
Java_com_example_goanime_1tv_Seq2SeqBridge_nativeFree(JNIEnv*, jobject, jlong handle) {
  auto* bundle = reinterpret_cast<std::vector<Session*>*>(handle);
  if (bundle == nullptr) return;
  for (auto* s : *bundle) close_session(s);
  delete bundle;
}

}  // extern "C"
