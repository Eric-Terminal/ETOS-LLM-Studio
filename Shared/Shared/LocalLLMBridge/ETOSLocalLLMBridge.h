// ============================================================================
// ETOSLocalLLMBridge.h
// ============================================================================
// ETOS LLM Studio
//
// Shared Framework 暴露给 Swift 的本地 llama.cpp C 接口。
// ============================================================================

#ifndef ETOS_LOCAL_LLM_BRIDGE_H
#define ETOS_LOCAL_LLM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t etos_local_llm_generate(
    const char * model_path,
    const char * prompt,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    char ** output,
    char ** error_message
);

void etos_local_llm_free(char * pointer);

#ifdef __cplusplus
}
#endif

#endif
