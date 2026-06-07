// ============================================================================
// ETOSLocalLLMBridge.cpp
// ============================================================================
// ETOS LLM Studio
//
// ETOSCore Framework 暴露给 Swift 的本地 llama.cpp C ABI 出入口。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"

int32_t etos_local_llm_generate(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_generation_config * config,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** output,
    char ** error_message
) {
    if (output) {
        *output = nullptr;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!output) {
        return etos_local_llm_bridge::fail("本地推理参数无效。", error_message);
    }

    std::string response;
    const int32_t status = etos_local_llm_bridge::generate(
        model_path,
        prompt,
        nullptr,
        nullptr,
        config,
        &response,
        nullptr,
        nullptr,
        nullptr,
        cancel_callback,
        user_data,
        error_message
    );
    if (status != 0) {
        return status;
    }

    *output = etos_local_llm_bridge::copy_string(response);
    return *output ? 0 : etos_local_llm_bridge::fail("本地模型输出内存分配失败。", error_message);
}

int32_t etos_local_llm_generate_chat(
    const char * model_path,
    const char * messages_json,
    const char * tools_json,
    const etos_local_llm_generation_config * config,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** output,
    char ** error_message
) {
    if (output) {
        *output = nullptr;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!output) {
        return etos_local_llm_bridge::fail("本地推理参数无效。", error_message);
    }

    std::string response;
    const int32_t status = etos_local_llm_bridge::generate(
        model_path,
        nullptr,
        messages_json,
        tools_json,
        config,
        &response,
        nullptr,
        nullptr,
        nullptr,
        cancel_callback,
        user_data,
        error_message
    );
    if (status != 0) {
        return status;
    }

    *output = etos_local_llm_bridge::copy_string(response);
    return *output ? 0 : etos_local_llm_bridge::fail("本地模型输出内存分配失败。", error_message);
}

int32_t etos_local_llm_generate_chat_response(
    const char * model_path,
    const char * messages_json,
    const char * tools_json,
    const etos_local_llm_generation_config * config,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** output_json,
    char ** error_message
) {
    if (output_json) {
        *output_json = nullptr;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!output_json) {
        return etos_local_llm_bridge::fail("本地推理参数无效。", error_message);
    }

    std::string response_json;
    const int32_t status = etos_local_llm_bridge::generate(
        model_path,
        nullptr,
        messages_json,
        tools_json,
        config,
        nullptr,
        &response_json,
        nullptr,
        nullptr,
        cancel_callback,
        user_data,
        error_message
    );
    if (status != 0) {
        return status;
    }

    *output_json = etos_local_llm_bridge::copy_string(response_json);
    return *output_json ? 0 : etos_local_llm_bridge::fail("本地模型结构化输出内存分配失败。", error_message);
}

int32_t etos_local_llm_generate_stream(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_generation_config * config,
    etos_local_llm_token_callback token_callback,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** error_message
) {
    if (error_message) {
        *error_message = nullptr;
    }
    return etos_local_llm_bridge::generate(
        model_path,
        prompt,
        nullptr,
        nullptr,
        config,
        nullptr,
        nullptr,
        token_callback,
        nullptr,
        cancel_callback,
        user_data,
        error_message
    );
}

int32_t etos_local_llm_generate_chat_stream(
    const char * model_path,
    const char * messages_json,
    const char * tools_json,
    const etos_local_llm_generation_config * config,
    etos_local_llm_token_callback token_callback,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** error_message
) {
    if (error_message) {
        *error_message = nullptr;
    }
    return etos_local_llm_bridge::generate(
        model_path,
        nullptr,
        messages_json,
        tools_json,
        config,
        nullptr,
        nullptr,
        token_callback,
        nullptr,
        cancel_callback,
        user_data,
        error_message
    );
}

int32_t etos_local_llm_generate_chat_response_stream(
    const char * model_path,
    const char * messages_json,
    const char * tools_json,
    const etos_local_llm_generation_config * config,
    etos_local_llm_chat_snapshot_callback snapshot_callback,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** error_message
) {
    if (error_message) {
        *error_message = nullptr;
    }
    return etos_local_llm_bridge::generate(
        model_path,
        nullptr,
        messages_json,
        tools_json,
        config,
        nullptr,
        nullptr,
        nullptr,
        snapshot_callback,
        cancel_callback,
        user_data,
        error_message
    );
}

int32_t etos_local_llm_parse_chat_response(
    const char * model_path,
    const char * messages_json,
    const char * tools_json,
    const char * generated_text,
    int32_t is_partial,
    char ** output_json,
    char ** error_message
) {
    if (output_json) {
        *output_json = nullptr;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!output_json) {
        return etos_local_llm_bridge::fail("本地对话解析参数无效。", error_message);
    }

    std::string response_json;
    const int32_t status = etos_local_llm_bridge::parse_chat_response(
        model_path,
        messages_json,
        tools_json,
        generated_text,
        is_partial != 0,
        &response_json,
        error_message
    );
    if (status != 0) {
        return status;
    }

    *output_json = etos_local_llm_bridge::copy_string(response_json);
    return *output_json ? 0 : etos_local_llm_bridge::fail("本地对话解析输出内存分配失败。", error_message);
}

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
) {
    if (output) {
        *output = nullptr;
    }
    if (embedding_count) {
        *embedding_count = 0;
    }
    if (embedding_dimension) {
        *embedding_dimension = 0;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!output || !embedding_count || !embedding_dimension) {
        return etos_local_llm_bridge::fail("本地嵌入参数无效。", error_message);
    }

    std::vector<float> embeddings;
    const int32_t status = etos_local_llm_bridge::embed(
        model_path,
        texts,
        text_count,
        context_size,
        n_gpu_layers,
        &embeddings,
        embedding_dimension,
        error_message
    );
    if (status != 0) {
        return status;
    }

    const size_t byte_count = embeddings.size() * sizeof(float);
    float * copied = static_cast<float *>(std::malloc(byte_count));
    if (!copied) {
        return etos_local_llm_bridge::fail("本地嵌入向量内存分配失败。", error_message);
    }
    std::memcpy(copied, embeddings.data(), byte_count);
    *output = copied;
    *embedding_count = text_count;
    return 0;
}

void etos_local_llm_free(char * pointer) {
    std::free(pointer);
}

void etos_local_llm_free_float(float * pointer) {
    std::free(pointer);
}

void etos_local_llm_clear_model_cache(void) {
    etos_local_llm_bridge::clear_model_cache();
}
