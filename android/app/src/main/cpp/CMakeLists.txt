cmake_minimum_required(VERSION 3.22)
project(goanime_llm)

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
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(GGML_CPU_ARM_ARCH "armv8.5-a+fp16+i8mm" CACHE STRING "" FORCE)
    endif()
    add_subdirectory(llama.cpp)

    add_library(goanime_llm SHARED goanime_llm.cpp)
    target_link_libraries(goanime_llm PRIVATE llama)
    target_include_directories(goanime_llm PRIVATE llama.cpp/include)
else()
    add_library(goanime_llm SHARED stub.cpp)
endif()
