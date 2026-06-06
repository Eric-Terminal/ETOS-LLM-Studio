// ============================================================================
// ETOSLocalLLMBridgeInternal.h
// ============================================================================
// ETOS LLM Studio
//
// 本地 llama.cpp C shim 的 C++ 内部接口，避免公开头暴露底层类型。
// ============================================================================

#ifndef ETOS_LOCAL_LLM_BRIDGE_INTERNAL_H
#define ETOS_LOCAL_LLM_BRIDGE_INTERNAL_H

#include "ETOSLocalLLMBridge.h"

#include "chat.h"
#include "ggml-backend.h"
#include "llama.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <TargetConditionals.h>
#include <thread>
#include <vector>

namespace etos_local_llm_bridge {

extern std::once_flag backend_init_once;
constexpr int32_t local_llm_cancelled_status = -2;

struct llama_model_deleter {
    void operator()(llama_model * model) const {
        if (model) {
            llama_model_free(model);
        }
    }
};

struct llama_context_deleter {
    void operator()(llama_context * context) const {
        if (context) {
            llama_free(context);
        }
    }
};

struct llama_sampler_deleter {
    void operator()(llama_sampler * sampler) const {
        if (sampler) {
            llama_sampler_free(sampler);
        }
    }
};

using llama_model_handle = std::unique_ptr<llama_model, llama_model_deleter>;
using llama_context_handle = std::unique_ptr<llama_context, llama_context_deleter>;
using llama_sampler_handle = std::unique_ptr<llama_sampler, llama_sampler_deleter>;

char * copy_string(const std::string & value);
int32_t fail(const std::string & message, char ** error_message);
int32_t cancelled(char ** error_message);
bool should_cancel(etos_local_llm_cancel_callback cancel_callback, void * user_data);
int32_t thread_count();

struct local_generation_params {
    int32_t context_size = 2048;
    int32_t max_output_tokens = 512;
    int32_t gpu_layers = -1;
    uint32_t seed = LLAMA_DEFAULT_SEED;
    int32_t min_keep = 0;
    int32_t top_k = 0;
    float top_p = 1.0f;
    float min_p = 0.0f;
    float typical_p = 1.0f;
    float temperature = 1.0f;
    float dynatemp_range = 0.0f;
    float dynatemp_exponent = 1.0f;
    float xtc_probability = 0.0f;
    float xtc_threshold = 0.1f;
    float top_n_sigma = -1.0f;
    int32_t repeat_last_n = 64;
    float repeat_penalty = 1.0f;
    float frequency_penalty = 0.0f;
    float presence_penalty = 0.0f;
    float dry_multiplier = 0.0f;
    float dry_base = 1.75f;
    int32_t dry_allowed_length = 2;
    int32_t dry_penalty_last_n = -1;
    std::vector<std::string> dry_sequence_breakers = {"\n", ":", "\"", "*"};
    int32_t mirostat = 0;
    float mirostat_tau = 5.0f;
    float mirostat_eta = 0.1f;
    float adaptive_target = -1.0f;
    float adaptive_decay = 0.9f;
    std::vector<int32_t> sampler_kinds = {
        ETOS_LOCAL_LLM_SAMPLER_TEMPERATURE,
    };
    std::string grammar;
    bool grammar_lazy = false;
    bool grammar_needs_prefill = false;
    std::vector<common_grammar_trigger> grammar_triggers;
    std::string generation_prompt;
    std::vector<std::string> additional_stops;
    bool ignore_eos = false;
};

local_generation_params generation_params_from_config(const etos_local_llm_generation_config & config);
std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool add_special = true);

int32_t generate(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    const etos_local_llm_generation_config * config,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** error_message
);

int32_t embed(
    const char * model_path,
    const char * const * texts,
    int32_t text_count,
    int32_t context_size,
    int32_t n_gpu_layers,
    std::vector<float> * output_embeddings,
    int32_t * embedding_dimension,
    char ** error_message
);

} // namespace etos_local_llm_bridge

#endif
