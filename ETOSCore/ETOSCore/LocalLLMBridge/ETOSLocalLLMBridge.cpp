// ============================================================================
// ETOSLocalLLMBridge.cpp
// ============================================================================
// ETOS LLM Studio
//
// ETOSCore Framework 暴露给 Swift 的本地 llama.cpp C ABI 出入口。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"
#include "ETOSLocalSpeechInternal.h"

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
    int32_t input_count,
    const etos_local_llm_embedding_config * config,
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
        input_count,
        config,
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
    *embedding_count = input_count;
    return 0;
}

int32_t etos_local_gguf_architecture(
    const char * model_path,
    char ** architecture,
    char ** error_message
) {
    if (architecture) {
        *architecture = nullptr;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!model_path || !architecture) {
        return etos_local_llm_bridge::fail("GGUF 架构探测参数无效。", error_message);
    }

    try {
        const std::string name = etos_local_speech::architecture_name(model_path);
        *architecture = etos_local_llm_bridge::copy_string(name);
        return *architecture
            ? 0
            : etos_local_llm_bridge::fail("GGUF 架构名称内存分配失败。", error_message);
    } catch (const std::exception & exception) {
        return etos_local_llm_bridge::fail(exception.what(), error_message);
    }
}

int32_t etos_local_speech_transcribe(
    const char * model_path,
    const float * audio_samples,
    int32_t sample_count,
    const etos_local_speech_config * config,
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
    if (!model_path || !audio_samples || sample_count <= 0 || !config || !output) {
        return etos_local_llm_bridge::fail("本地语音转写参数无效。", error_message);
    }

    etos_local_speech::transcription_options options;
    options.decoder_model_path = config->decoder_model_path
        ? config->decoder_model_path
        : "";
    options.vad_model_path = config->vad_model_path
        ? config->vad_model_path
        : "";
    options.context_size = std::max(256, config->context_size);
    options.max_output_tokens = std::max(1, config->max_output_tokens);
    options.gpu_layers = config->gpu_layers;
    options.threads = config->thread_count > 0
        ? config->thread_count
        : etos_local_llm_bridge::thread_count();
    options.chunk_seconds = std::max(1, config->chunk_seconds);
    options.vad_max_segment_milliseconds = std::max(
        1000,
        config->vad_max_segment_milliseconds
    );
    options.use_model_cache = config->use_model_cache != 0;
    options.cancel_callback = cancel_callback;
    options.user_data = user_data;

    try {
        const std::string path(model_path);
        const std::string name = etos_local_speech::architecture_name(path);
        const std::vector<float> waveform(audio_samples, audio_samples + sample_count);
        std::string text;
        switch (etos_local_speech::architecture_from_name(name)) {
        case etos_local_speech::architecture::sense_voice:
            text = etos_local_speech::transcribe_sense_voice(path, waveform, options);
            break;
        case etos_local_speech::architecture::paraformer:
            text = etos_local_speech::transcribe_paraformer(path, waveform, options);
            break;
        case etos_local_speech::architecture::fun_asr_nano_encoder:
            if (options.decoder_model_path.empty()) {
                return etos_local_llm_bridge::fail(
                    "Fun-ASR-Nano 需要关联一个本地 Qwen 解码模型。",
                    error_message
                );
            }
            text = etos_local_speech::transcribe_fun_asr_nano(path, waveform, options);
            break;
        case etos_local_speech::architecture::fsmn_vad:
            return etos_local_llm_bridge::fail(
                "FSMN-VAD 是语音分段辅助模型，不能单独执行语音转写。",
                error_message
            );
        case etos_local_speech::architecture::unknown:
            return etos_local_llm_bridge::fail(
                "当前本地语音运行时尚未实现 GGUF 架构：" + name,
                error_message
            );
        }

        *output = etos_local_llm_bridge::copy_string(text);
        return *output
            ? 0
            : etos_local_llm_bridge::fail("本地语音转写结果内存分配失败。", error_message);
    } catch (const std::exception & exception) {
        if (etos_local_llm_bridge::should_cancel(cancel_callback, user_data)) {
            return etos_local_llm_bridge::cancelled(error_message);
        }
        return etos_local_llm_bridge::fail(exception.what(), error_message);
    }
}

void etos_local_llm_free(char * pointer) {
    std::free(pointer);
}

void etos_local_llm_free_float(float * pointer) {
    std::free(pointer);
}

void etos_local_llm_clear_kv_cache(const char * expected_cache_key) {
    etos_local_llm_bridge::clear_kv_cache(expected_cache_key);
}

void etos_local_llm_clear_model_cache(void) {
    etos_local_llm_bridge::clear_kv_cache(nullptr);
    etos_local_llm_bridge::clear_model_cache();
    etos_local_speech::clear_speech_model_cache();
}
