// ============================================================================
// ETOSLocalLLMBridge.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 的极薄 C shim，避免 Swift 和 UI 感知底层 C++ 结构。
// ============================================================================

#include "ETOSLocalLLMBridge.h"

#include "ggml-backend.h"
#include "llama.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <mutex>
#include <string>
#include <TargetConditionals.h>
#include <thread>
#include <vector>

namespace {

std::once_flag backend_init_once;

char * copy_string(const std::string & value) {
    char * result = static_cast<char *>(std::malloc(value.size() + 1));
    if (!result) {
        return nullptr;
    }
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

int32_t fail(const std::string & message, char ** error_message) {
    if (error_message) {
        *error_message = copy_string(message);
    }
    return -1;
}

int32_t thread_count() {
    const int processors = static_cast<int>(std::thread::hardware_concurrency());
    return static_cast<int32_t>(std::max(1, std::min(8, processors > 2 ? processors - 2 : processors)));
}

std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & prompt) {
    const int32_t token_count = -llama_tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()), nullptr, 0, true, true);
    if (token_count <= 0) {
        return {};
    }
    std::vector<llama_token> tokens(static_cast<size_t>(token_count));
    const int32_t written = llama_tokenize(
        vocab,
        prompt.c_str(),
        static_cast<int32_t>(prompt.size()),
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        true,
        true
    );
    if (written < 0) {
        return {};
    }
    tokens.resize(static_cast<size_t>(written));
    return tokens;
}

void batch_add(llama_batch & batch, llama_token token, llama_pos position, llama_seq_id sequence_id, bool output) {
    batch.token[batch.n_tokens] = token;
    batch.pos[batch.n_tokens] = position;
    batch.n_seq_id[batch.n_tokens] = 1;
    batch.seq_id[batch.n_tokens][0] = sequence_id;
    batch.logits[batch.n_tokens] = output ? 1 : 0;
    batch.n_tokens += 1;
}

void normalize_embedding(const float * input, float * output, int32_t dimension) {
    double sum = 0.0;
    for (int32_t index = 0; index < dimension; ++index) {
        sum += static_cast<double>(input[index]) * static_cast<double>(input[index]);
    }
    const float scale = sum > 0.0 ? static_cast<float>(1.0 / std::sqrt(sum)) : 0.0f;
    for (int32_t index = 0; index < dimension; ++index) {
        output[index] = input[index] * scale;
    }
}

std::string apply_chat_template(
    const llama_model * model,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    char ** error_message
) {
    if (!messages || message_count <= 0) {
        fail("本地对话消息为空。", error_message);
        return {};
    }

    std::vector<llama_chat_message> chat_messages;
    chat_messages.reserve(static_cast<size_t>(message_count));
    for (int32_t index = 0; index < message_count; ++index) {
        const char * role = messages[index].role;
        const char * content = messages[index].content;
        if (!role || !content || content[0] == '\0') {
            continue;
        }
        chat_messages.push_back({ role, content });
    }

    if (chat_messages.empty()) {
        fail("本地对话消息为空。", error_message);
        return {};
    }

    const char * tmpl = llama_model_chat_template(model, nullptr);
    if (!tmpl) {
        fail("本地模型缺少 GGUF tokenizer.chat_template。", error_message);
        return {};
    }

    int32_t formatted_size = llama_chat_apply_template(tmpl, chat_messages.data(), chat_messages.size(), true, nullptr, 0);
    if (formatted_size < 0) {
        fail("本地模型的聊天模板暂不受 llama.cpp 当前模板 API 支持。", error_message);
        return {};
    }

    std::vector<char> formatted(static_cast<size_t>(formatted_size));
    formatted_size = llama_chat_apply_template(
        tmpl,
        chat_messages.data(),
        chat_messages.size(),
        true,
        formatted.data(),
        static_cast<int32_t>(formatted.size())
    );
    if (formatted_size < 0) {
        fail("本地模型应用聊天模板失败。", error_message);
        return {};
    }
    if (static_cast<size_t>(formatted_size) > formatted.size()) {
        formatted.resize(static_cast<size_t>(formatted_size));
        formatted_size = llama_chat_apply_template(
            tmpl,
            chat_messages.data(),
            chat_messages.size(),
            true,
            formatted.data(),
            static_cast<int32_t>(formatted.size())
        );
    }
    if (formatted_size < 0 || static_cast<size_t>(formatted_size) > formatted.size()) {
        fail("本地模型应用聊天模板失败。", error_message);
        return {};
    }

    return std::string(formatted.data(), static_cast<size_t>(formatted_size));
}

int32_t generate(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
    void * user_data,
    char ** error_message
) {
    if (!model_path || (!prompt && (!messages || message_count <= 0))) {
        return fail("本地推理参数无效。", error_message);
    }
    if (!output_text && !token_callback) {
        return fail("本地推理输出参数无效。", error_message);
    }

    std::call_once(backend_init_once, [] {
        llama_backend_init();
        ggml_backend_load_all();
    });

    llama_model_params model_params = llama_model_default_params();
#if TARGET_OS_WATCH || TARGET_OS_SIMULATOR
    model_params.n_gpu_layers = 0;
#else
    model_params.n_gpu_layers = n_gpu_layers < 0 ? 999 : n_gpu_layers;
#endif

    llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (!model) {
        return fail("无法加载本地模型权重。", error_message);
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    std::string templated_prompt;
    if (!prompt) {
        templated_prompt = apply_chat_template(model, messages, message_count, error_message);
        if (templated_prompt.empty()) {
            llama_model_free(model);
            return -1;
        }
        prompt = templated_prompt.c_str();
    }

    std::vector<llama_token> prompt_tokens = tokenize(vocab, prompt);
    if (prompt_tokens.empty()) {
        llama_model_free(model);
        return fail("本地模型无法解析提示词。", error_message);
    }

    const int32_t requested_context = std::max<int32_t>(1, context_size);
    const int32_t requested_output = std::max<int32_t>(1, max_output_tokens);
    const int32_t required_context = static_cast<int32_t>(prompt_tokens.size()) + requested_output;

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = std::max(requested_context, required_context);
    ctx_params.n_batch = std::min<int32_t>(ctx_params.n_ctx, static_cast<int32_t>(prompt_tokens.size()));
    ctx_params.n_threads = thread_count();
    ctx_params.n_threads_batch = ctx_params.n_threads;

    llama_context * ctx = llama_init_from_model(model, ctx_params);
    if (!ctx) {
        llama_model_free(model);
        return fail("无法创建本地模型上下文。", error_message);
    }

    llama_sampler * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (top_p > 0 && top_p < 1) {
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(top_p, 1));
    }
    if (temperature > 0) {
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    }

    llama_batch batch = llama_batch_get_one(prompt_tokens.data(), static_cast<int32_t>(prompt_tokens.size()));
    int32_t generated_tokens = 0;

    while (generated_tokens < requested_output) {
        if (llama_decode(ctx, batch) != 0) {
            llama_sampler_free(sampler);
            llama_free(ctx);
            llama_model_free(model);
            return fail("本地模型解码失败。", error_message);
        }

        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            break;
        }

        char buffer[512];
        const int32_t written = llama_token_to_piece(vocab, token, buffer, sizeof(buffer), 0, true);
        if (written < 0) {
            llama_sampler_free(sampler);
            llama_free(ctx);
            llama_model_free(model);
            return fail("本地模型输出转换失败。", error_message);
        }

        std::string piece(buffer, static_cast<size_t>(written));
        if (output_text) {
            output_text->append(piece);
        }
        if (token_callback && token_callback(piece.c_str(), user_data) == 0) {
            break;
        }

        batch = llama_batch_get_one(&token, 1);
        generated_tokens += 1;
    }

    llama_sampler_free(sampler);
    llama_free(ctx);
    llama_model_free(model);
    return 0;
}

int32_t embed(
    const char * model_path,
    const char * const * texts,
    int32_t text_count,
    int32_t context_size,
    int32_t n_gpu_layers,
    std::vector<float> * output_embeddings,
    int32_t * embedding_dimension,
    char ** error_message
) {
    if (!model_path || !texts || text_count <= 0 || !output_embeddings || !embedding_dimension) {
        return fail("本地嵌入参数无效。", error_message);
    }

    std::call_once(backend_init_once, [] {
        llama_backend_init();
        ggml_backend_load_all();
    });

    llama_model_params model_params = llama_model_default_params();
#if TARGET_OS_WATCH || TARGET_OS_SIMULATOR
    model_params.n_gpu_layers = 0;
#else
    model_params.n_gpu_layers = n_gpu_layers < 0 ? 999 : n_gpu_layers;
#endif

    llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (!model) {
        return fail("无法加载本地嵌入模型权重。", error_message);
    }
    if (llama_model_has_encoder(model) && llama_model_has_decoder(model)) {
        llama_model_free(model);
        return fail("当前 llama.cpp 不支持 encoder-decoder 模型生成嵌入。", error_message);
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    std::vector<std::vector<llama_token>> tokenized_inputs;
    tokenized_inputs.reserve(static_cast<size_t>(text_count));
    int32_t max_token_count = 1;
    for (int32_t index = 0; index < text_count; ++index) {
        const char * text = texts[index];
        if (!text || text[0] == '\0') {
            llama_model_free(model);
            return fail("本地嵌入文本不能为空。", error_message);
        }
        auto tokens = tokenize(vocab, text);
        if (tokens.empty()) {
            llama_model_free(model);
            return fail("本地嵌入模型无法解析输入文本。", error_message);
        }
        max_token_count = std::max<int32_t>(max_token_count, static_cast<int32_t>(tokens.size()));
        tokenized_inputs.push_back(std::move(tokens));
    }

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.embeddings = true;
    ctx_params.n_ctx = std::max<int32_t>(std::max(1, context_size), max_token_count);
    ctx_params.n_batch = ctx_params.n_ctx;
    ctx_params.n_ubatch = ctx_params.n_batch;
    ctx_params.n_threads = thread_count();
    ctx_params.n_threads_batch = ctx_params.n_threads;

    llama_context * ctx = llama_init_from_model(model, ctx_params);
    if (!ctx) {
        llama_model_free(model);
        return fail("无法创建本地嵌入上下文。", error_message);
    }
    llama_set_embeddings(ctx, true);

    const int32_t dimension = llama_model_n_embd_out(model);
    if (dimension <= 0) {
        llama_free(ctx);
        llama_model_free(model);
        return fail("本地嵌入模型输出维度无效。", error_message);
    }

    output_embeddings->assign(static_cast<size_t>(text_count) * static_cast<size_t>(dimension), 0.0f);
    for (int32_t text_index = 0; text_index < text_count; ++text_index) {
        const auto & tokens = tokenized_inputs[static_cast<size_t>(text_index)];
        if (static_cast<int32_t>(tokens.size()) > static_cast<int32_t>(ctx_params.n_batch)) {
            llama_free(ctx);
            llama_model_free(model);
            return fail("本地嵌入输入超过上下文窗口。", error_message);
        }

        llama_memory_clear(llama_get_memory(ctx), true);
        llama_batch batch = llama_batch_init(static_cast<int32_t>(tokens.size()), 0, 1);
        for (int32_t token_index = 0; token_index < static_cast<int32_t>(tokens.size()); ++token_index) {
            batch_add(batch, tokens[static_cast<size_t>(token_index)], token_index, 0, true);
        }

        const int32_t token_count = static_cast<int32_t>(tokens.size());
        const int32_t status = llama_decode(ctx, batch);
        llama_batch_free(batch);
        if (status < 0) {
            llama_free(ctx);
            llama_model_free(model);
            return fail("本地嵌入模型解码失败。", error_message);
        }

        float * destination = output_embeddings->data() + static_cast<size_t>(text_index) * static_cast<size_t>(dimension);
        const float * embedding = llama_get_embeddings_seq(ctx, 0);
        if (embedding) {
            normalize_embedding(embedding, destination, dimension);
            continue;
        }

        std::vector<float> mean(static_cast<size_t>(dimension), 0.0f);
        int32_t pooled_count = 0;
        for (int32_t token_index = 0; token_index < token_count; ++token_index) {
            const float * token_embedding = llama_get_embeddings_ith(ctx, token_index);
            if (!token_embedding) {
                continue;
            }
            for (int32_t dimension_index = 0; dimension_index < dimension; ++dimension_index) {
                mean[static_cast<size_t>(dimension_index)] += token_embedding[dimension_index];
            }
            pooled_count += 1;
        }
        if (pooled_count == 0) {
            llama_free(ctx);
            llama_model_free(model);
            return fail("无法读取本地嵌入向量。", error_message);
        }
        for (float & value : mean) {
            value /= static_cast<float>(pooled_count);
        }
        normalize_embedding(mean.data(), destination, dimension);
    }

    *embedding_dimension = dimension;
    llama_free(ctx);
    llama_model_free(model);
    return 0;
}

} // namespace

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
) {
    if (output) {
        *output = nullptr;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!output) {
        return fail("本地推理参数无效。", error_message);
    }

    std::string response;
    const int32_t status = generate(
        model_path,
        prompt,
        nullptr,
        0,
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        &response,
        nullptr,
        nullptr,
        error_message
    );
    if (status != 0) {
        return status;
    }

    *output = copy_string(response);
    return *output ? 0 : fail("本地模型输出内存分配失败。", error_message);
}

int32_t etos_local_llm_generate_chat(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
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
        return fail("本地推理参数无效。", error_message);
    }

    std::string response;
    const int32_t status = generate(
        model_path,
        nullptr,
        messages,
        message_count,
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        &response,
        nullptr,
        nullptr,
        error_message
    );
    if (status != 0) {
        return status;
    }

    *output = copy_string(response);
    return *output ? 0 : fail("本地模型输出内存分配失败。", error_message);
}

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
) {
    if (error_message) {
        *error_message = nullptr;
    }
    return generate(
        model_path,
        prompt,
        nullptr,
        0,
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        nullptr,
        token_callback,
        user_data,
        error_message
    );
}

int32_t etos_local_llm_generate_chat_stream(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    etos_local_llm_token_callback token_callback,
    void * user_data,
    char ** error_message
) {
    if (error_message) {
        *error_message = nullptr;
    }
    return generate(
        model_path,
        nullptr,
        messages,
        message_count,
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        nullptr,
        token_callback,
        user_data,
        error_message
    );
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
        return fail("本地嵌入参数无效。", error_message);
    }

    std::vector<float> embeddings;
    const int32_t status = embed(
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
        return fail("本地嵌入向量内存分配失败。", error_message);
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
