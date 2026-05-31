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

typedef int32_t (*etos_local_llm_token_callback)(const char * text, void * user_data);

typedef struct etos_local_llm_chat_message {
    const char * role;
    const char * content;
    const char * name;
    const char * tool_call_id;
    const char * tool_calls_json;
} etos_local_llm_chat_message;

typedef struct etos_local_llm_tool {
    const char * name;
    const char * description;
    const char * parameters_json;
} etos_local_llm_tool;

typedef struct etos_local_llm_tool_call {
    char * id;
    char * name;
    char * arguments;
} etos_local_llm_tool_call;

int32_t etos_local_llm_generate(
    const char * model_path,
    const char * prompt,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    char ** output,
    char ** error_message
);

int32_t etos_local_llm_generate_chat(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    char ** output,
    char ** error_message
);

int32_t etos_local_llm_generate_stream(
    const char * model_path,
    const char * prompt,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    etos_local_llm_token_callback token_callback,
    void * user_data,
    char ** error_message
);

int32_t etos_local_llm_generate_chat_stream(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    etos_local_llm_token_callback token_callback,
    void * user_data,
    char ** error_message
);

int32_t etos_local_llm_embed(
    const char * model_path,
    const char * const * texts,
    int32_t text_count,
    int32_t context_size,
    int32_t n_gpu_layers,
    float ** output,
    int32_t * embedding_count,
    int32_t * embedding_dimension,
    char ** error_message
);

int32_t etos_local_llm_parse_tool_calls(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    const char * generated_text,
    char ** content,
    etos_local_llm_tool_call ** tool_calls,
    int32_t * tool_call_count,
    char ** error_message
);

void etos_local_llm_free(char * pointer);
void etos_local_llm_free_float(float * pointer);
void etos_local_llm_free_tool_calls(etos_local_llm_tool_call * pointer, int32_t count);

#ifdef __cplusplus
}
#endif

#endif
