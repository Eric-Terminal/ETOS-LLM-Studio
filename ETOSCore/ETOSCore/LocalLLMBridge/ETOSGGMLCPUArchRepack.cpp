// ============================================================================
// ETOSGGMLCPUArchRepack.cpp
// ============================================================================
// ETOS LLM Studio
//
// 按当前架构选择 ggml CPU repack 实现。watchOS 的 arm64_32 会落入 ARM
// 分支，保持纯 CPU 推理链路可用。
// ============================================================================

#if defined(__aarch64__) || defined(__arm64__) || defined(__arm64_32__) || defined(__arm__)
#include "../../../Dependencies/llama.cpp/ggml/src/ggml-cpu/arch/arm/repack.cpp"
#elif defined(__x86_64__) || defined(__i386__)
#include "../../../Dependencies/llama.cpp/ggml/src/ggml-cpu/arch/x86/repack.cpp"
#endif
