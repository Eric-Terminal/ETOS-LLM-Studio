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

typedef enum etos_local_llm_sampler_kind {
    ETOS_LOCAL_LLM_SAMPLER_PENALTIES = 1,
    ETOS_LOCAL_LLM_SAMPLER_DRY = 2,
    ETOS_LOCAL_LLM_SAMPLER_TOP_N_SIGMA = 3,
    ETOS_LOCAL_LLM_SAMPLER_TOP_K = 4,
    ETOS_LOCAL_LLM_SAMPLER_TYPICAL = 5,
    ETOS_LOCAL_LLM_SAMPLER_TOP_P = 6,
    ETOS_LOCAL_LLM_SAMPLER_MIN_P = 7,
    ETOS_LOCAL_LLM_SAMPLER_XTC = 8,
    ETOS_LOCAL_LLM_SAMPLER_TEMPERATURE = 9,
    ETOS_LOCAL_LLM_SAMPLER_ADAPTIVE = 10,
} etos_local_llm_sampler_kind;

typedef struct etos_local_llm_generation_config {
    int32_t context_size;
    int32_t max_output_tokens;
    int32_t gpu_layers;
    uint32_t seed;
    int32_t min_keep;
    int32_t top_k;
    float top_p;
    float min_p;
    float typical_p;
    float temperature;
    float dynatemp_range;
    float dynatemp_exponent;
    float xtc_probability;
    float xtc_threshold;
    float top_n_sigma;
    int32_t repeat_last_n;
    float repeat_penalty;
    float frequency_penalty;
    float presence_penalty;
    float dry_multiplier;
    float dry_base;
    int32_t dry_allowed_length;
    int32_t dry_penalty_last_n;
    const char * const * dry_sequence_breakers;
    int32_t dry_sequence_breaker_count;
    const int32_t * sampler_kinds;
    int32_t sampler_kind_count;
    int32_t mirostat;
    float mirostat_tau;
    float mirostat_eta;
    float adaptive_target;
    float adaptive_decay;
    const char * grammar;
    int32_t ignore_eos;
} etos_local_llm_generation_config;

int32_t etos_local_llm_generate(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_generation_config * config,
    char ** output,
    char ** error_message
);

int32_t etos_local_llm_generate_chat(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    const etos_local_llm_generation_config * config,
    char ** output,
    char ** error_message
);

int32_t etos_local_llm_generate_stream(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_generation_config * config,
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
    const etos_local_llm_generation_config * config,
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
