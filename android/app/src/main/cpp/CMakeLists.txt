cmake_minimum_required(VERSION 3.22)
project(goanime_llm)

include(FetchContent)

# llama.cpp pinado no commit validado no spike (d1d3c33, 2026-09-15).
# Baixado via git na 1ª configuração (CI e dev local precisam de rede, como
# o `flutter pub get`). Sem submodule de propósito: o checkout do CI não
# traz submodules e quebraria o build.
FetchContent_Declare(
    llama
    GIT_REPOSITORY https://github.com/ggml-org/llama.cpp
    GIT_TAG d1d3c3396aa13a5f239109a822666c4870490ad5
    GIT_PROGRESS TRUE
)

# llama.cpp upstream só compila em 64-bit (o sgemm deles exige FP16 NEON,
# ausente no armeabi-v7a — falha COMPILE, não runtime). 32-bit recebe um stub
# vazio: loadLibrary passa, e a 1ª chamada vira erro amigável no Dart
# ("tradução local indisponível neste aparelho"). Sem patch no upstream.
if(ANDROID_ABI STREQUAL "arm64-v8a" OR ANDROID_ABI STREQUAL "x86_64")
    # llama.cpp enxuto: só o core (sem tests/examples/server/tools). O app usa
    # a C API (llama.h) direto; sem `common/` (template montado no Kotlin com o
    # formato validado no spike, greedy temp 0).
    set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
    set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
    # SEM GGML_CPU_ARM_ARCH de propósito (SIGILL no Edge 30/SD778G):
    # a flag antiga "armv8.5-a+fp16+i8mm" emitia stlur (LRCPC2/3) + smmla
    # fora do baseline da CPU (tombstones SIGILL ILL_ILLOPC, PC 0x3e6d4,
    # BuildId libggml-cpu.so 5ef021c5). Sem a var = baseline do NDK
    # (armv8-a, NEON puro): seguro em A78/A55 e em sticks A53 (v8.0, sem
    # dotprod). Sem dispatch dinâmico (BACKEND_DL=OFF) — perda de
    # dotprod/i8mm até prova em contrário. NÃO forçar armv8.2+dotprod
    # (quebra A53) nem armv8-a+fp16 (+fp16 vetorial é v8.2+, não v8.0).
    # KLEIDIAI travado em OFF: os ukernels *_neon_i8mm.c só entram com ON.
    set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(llama)

    add_library(goanime_llm SHARED goanime_llm.cpp)
    find_library(log-lib log)
    target_link_libraries(goanime_llm PRIVATE llama ${log-lib})
    target_include_directories(goanime_llm PRIVATE ${llama_SOURCE_DIR}/include)
else()
    add_library(goanime_llm SHARED stub.cpp)
endif()
