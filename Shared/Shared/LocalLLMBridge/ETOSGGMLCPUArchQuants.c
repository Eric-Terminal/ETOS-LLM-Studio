// ============================================================================
// ETOSGGMLCPUArchQuants.c
// ============================================================================
// ETOS LLM Studio
//
// 按当前架构选择 ggml CPU 量化实现，避免通用 iOS Simulator 同时链接
// ARM 与 x86 的同名符号。
// ============================================================================

#if defined(__aarch64__) || defined(__arm64__) || defined(__arm64_32__) || defined(__arm__)
#include "../../../Dependencies/llama.cpp/ggml/src/ggml-cpu/arch/arm/quants.c"
#elif defined(__x86_64__) || defined(__i386__)
#include "../../../Dependencies/llama.cpp/ggml/src/ggml-cpu/arch/x86/quants.c"
#endif
