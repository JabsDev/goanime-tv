cmake_minimum_required(VERSION 3.22)
project(goanime_native)

include(FetchContent)

# llama.cpp pinado no commit validado no spike (d1d3c33, 2026-09-15).
FetchContent_Declare(
    llama
    GIT_REPOSITORY https://github.com/ggml-org/llama.cpp
    GIT_TAG d1d3c3396aa13a5f239109a822666c4870490ad5
    GIT_PROGRESS TRUE
)

# llama.cpp upstream só compila em 64-bit (o sgemm deles exige FP16 NEON,
# ausente no armeabi-v7a — falha COMPILE, não runtime). 32-bit recebe um stub
# vazio: loadLibrary passa, e a 1ª chamada vira erro amigável no Dart.
# O STT jav03 segue o mesmo padrão (o ONNX Runtime do sherpa só vai em 64-bit).
if(ANDROID_ABI STREQUAL "arm64-v8a" OR ANDROID_ABI STREQUAL "x86_64")
    set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
    set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
    # SEM GGML_CPU_ARM_ARCH de propósito (SIGILL no Edge 30/SD778G).
    set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(llama)

    add_library(goanime_llm SHARED goanime_llm.cpp)
    find_library(log-lib log)
    target_link_libraries(goanime_llm PRIVATE llama ${log-lib})
    target_include_directories(goanime_llm PRIVATE ${llama_SOURCE_DIR}/include)

    # STT whisper-ja-anime-v0.3 sobre o ONNX Runtime JA embarcado no APK
    # (libonnxruntime.so do fork sherpa). dlopen em runtime — sem -lonnxruntime
    # (o .so vive nos jniLibs do plugin sherpa, fora do link path). O header
    # onnxruntime_c_api.h foi pinado em v1.28.2 (mesma major do .so).
    add_library(goanime_jav03_stt SHARED jav03_stt.cpp)
    find_library(dl-lib dl)
    target_link_libraries(goanime_jav03_stt PRIVATE ${log-lib} ${dl-lib})

    # Auditor JA seq2seq (ByT5 fine-tunado): mesmo ONNX Runtime via dlopen.
    add_library(goanime_audit SHARED audit_seq2seq.cpp)
    target_link_libraries(goanime_audit PRIVATE ${log-lib} ${dl-lib})
else()
    add_library(goanime_llm SHARED stub.cpp)
    add_library(goanime_jav03_stt SHARED jav03_stt/stub.cpp)
    add_library(goanime_audit SHARED audit_stub.cpp)
    find_library(log-lib log)
    target_link_libraries(goanime_jav03_stt PRIVATE ${log-lib})
    target_link_libraries(goanime_audit PRIVATE ${log-lib})
endif()
