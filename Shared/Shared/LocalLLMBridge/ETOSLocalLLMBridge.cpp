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
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <mutex>
#include <string>
#include <TargetConditionals.h>
#include <thread>
#include <utility>
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

struct local_generation_params {
    int32_t context_size = 2048;
    int32_t max_output_tokens = 512;
    int32_t gpu_layers = -1;
    uint32_t seed = LLAMA_DEFAULT_SEED;
    int32_t min_keep = 0;
    int32_t top_k = 40;
    float top_p = 0.95f;
    float min_p = 0.05f;
    float typical_p = 1.0f;
    float temperature = 0.8f;
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
        ETOS_LOCAL_LLM_SAMPLER_PENALTIES,
        ETOS_LOCAL_LLM_SAMPLER_DRY,
        ETOS_LOCAL_LLM_SAMPLER_TOP_N_SIGMA,
        ETOS_LOCAL_LLM_SAMPLER_TOP_K,
        ETOS_LOCAL_LLM_SAMPLER_TYPICAL,
        ETOS_LOCAL_LLM_SAMPLER_TOP_P,
        ETOS_LOCAL_LLM_SAMPLER_MIN_P,
        ETOS_LOCAL_LLM_SAMPLER_XTC,
        ETOS_LOCAL_LLM_SAMPLER_TEMPERATURE,
    };
    std::string grammar;
    bool ignore_eos = false;
};

local_generation_params generation_params_from_config(const etos_local_llm_generation_config & config) {
    local_generation_params params;
    params.context_size = std::max<int32_t>(1, config.context_size);
    params.max_output_tokens = std::max<int32_t>(1, config.max_output_tokens);
    params.gpu_layers = config.gpu_layers;
    params.seed = config.seed;
    params.min_keep = config.min_keep;
    params.top_k = config.top_k;
    params.top_p = config.top_p;
    params.min_p = config.min_p;
    params.typical_p = config.typical_p;
    params.temperature = config.temperature;
    params.dynatemp_range = config.dynatemp_range;
    params.dynatemp_exponent = config.dynatemp_exponent;
    params.xtc_probability = config.xtc_probability;
    params.xtc_threshold = config.xtc_threshold;
    params.top_n_sigma = config.top_n_sigma;
    params.repeat_last_n = config.repeat_last_n;
    params.repeat_penalty = config.repeat_penalty;
    params.frequency_penalty = config.frequency_penalty;
    params.presence_penalty = config.presence_penalty;
    params.dry_multiplier = config.dry_multiplier;
    params.dry_base = config.dry_base;
    params.dry_allowed_length = config.dry_allowed_length;
    params.dry_penalty_last_n = config.dry_penalty_last_n;
    params.dry_sequence_breakers.clear();
    for (int32_t index = 0; config.dry_sequence_breakers && index < config.dry_sequence_breaker_count; ++index) {
        const char * breaker = config.dry_sequence_breakers[index];
        if (breaker) {
            params.dry_sequence_breakers.emplace_back(breaker);
        }
    }
    params.mirostat = config.mirostat;
    params.mirostat_tau = config.mirostat_tau;
    params.mirostat_eta = config.mirostat_eta;
    params.adaptive_target = config.adaptive_target;
    params.adaptive_decay = config.adaptive_decay;
    params.sampler_kinds.clear();
    for (int32_t index = 0; config.sampler_kinds && index < config.sampler_kind_count; ++index) {
        params.sampler_kinds.push_back(config.sampler_kinds[index]);
    }
    params.grammar = config.grammar ? config.grammar : "";
    params.ignore_eos = config.ignore_eos != 0;
    return params;
}

llama_sampler * create_sampler(
    const llama_model * model,
    const llama_vocab * vocab,
    const local_generation_params & params
) {
    llama_sampler * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());

    if (params.ignore_eos) {
        llama_logit_bias eos_bias = {
            llama_vocab_eos(vocab),
            -INFINITY
        };
        llama_sampler_chain_add(sampler, llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), 1, &eos_bias));
    }

    const size_t min_keep = params.min_keep <= 0 ? 0 : static_cast<size_t>(params.min_keep);
    if (params.mirostat == 1) {
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(params.temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_mirostat(llama_vocab_n_tokens(vocab), params.seed, params.mirostat_tau, params.mirostat_eta, 100));
        return sampler;
    }
    if (params.mirostat == 2) {
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(params.temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_mirostat_v2(params.seed, params.mirostat_tau, params.mirostat_eta));
        return sampler;
    }

    bool uses_terminal_sampler = false;
    for (const int32_t sampler_kind : params.sampler_kinds) {
        switch (sampler_kind) {
        case ETOS_LOCAL_LLM_SAMPLER_PENALTIES:
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                params.repeat_last_n,
                params.repeat_penalty,
                params.frequency_penalty,
                params.presence_penalty
            ));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_DRY: {
            std::vector<const char *> breakers;
            breakers.reserve(params.dry_sequence_breakers.size());
            for (const std::string & breaker : params.dry_sequence_breakers) {
                breakers.push_back(breaker.c_str());
            }
            llama_sampler_chain_add(sampler, llama_sampler_init_dry(
                vocab,
                llama_model_n_ctx_train(model),
                params.dry_multiplier,
                params.dry_base,
                params.dry_allowed_length,
                params.dry_penalty_last_n,
                breakers.data(),
                breakers.size()
            ));
            break;
        }
        case ETOS_LOCAL_LLM_SAMPLER_TOP_N_SIGMA:
            llama_sampler_chain_add(sampler, llama_sampler_init_top_n_sigma(params.top_n_sigma));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_TOP_K:
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(params.top_k));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_TYPICAL:
            llama_sampler_chain_add(sampler, llama_sampler_init_typical(params.typical_p, min_keep));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_TOP_P:
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(params.top_p, min_keep));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_MIN_P:
            llama_sampler_chain_add(sampler, llama_sampler_init_min_p(params.min_p, min_keep));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_XTC:
            llama_sampler_chain_add(sampler, llama_sampler_init_xtc(params.xtc_probability, params.xtc_threshold, min_keep, params.seed));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_TEMPERATURE:
            llama_sampler_chain_add(sampler, llama_sampler_init_temp_ext(params.temperature, params.dynatemp_range, params.dynatemp_exponent));
            break;
        case ETOS_LOCAL_LLM_SAMPLER_ADAPTIVE:
            uses_terminal_sampler = true;
            break;
        default:
            break;
        }
    }

    if (!params.grammar.empty()) {
        llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocab, params.grammar.c_str(), "root"));
    }
    if (uses_terminal_sampler) {
        llama_sampler_chain_add(sampler, llama_sampler_init_adaptive_p(params.adaptive_target, params.adaptive_decay, params.seed));
    } else if (params.temperature <= 0.0f) {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(params.seed));
    }
    return sampler;
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

std::string token_to_piece(const llama_vocab * vocab, llama_token token) {
    char buffer[512];
    const int32_t written = llama_token_to_piece(vocab, token, buffer, sizeof(buffer), 0, true);
    if (written >= 0) {
        return std::string(buffer, static_cast<size_t>(written));
    }

    const size_t required_size = static_cast<size_t>(-written);
    std::vector<char> dynamic_buffer(required_size);
    const int32_t dynamic_written = llama_token_to_piece(
        vocab,
        token,
        dynamic_buffer.data(),
        static_cast<int32_t>(dynamic_buffer.size()),
        0,
        true
    );
    if (dynamic_written < 0) {
        return {};
    }
    return std::string(dynamic_buffer.data(), static_cast<size_t>(dynamic_written));
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

int32_t generate(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_generation_config * config,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
    void * user_data,
    char ** error_message
) {
    if (!model_path || !prompt || prompt[0] == '\0') {
        return fail("本地推理参数无效。", error_message);
    }
    if (!output_text && !token_callback) {
        return fail("本地推理输出参数无效。", error_message);
    }
    if (!config) {
        return fail("本地推理配置无效。", error_message);
    }

    const local_generation_params generation_params = generation_params_from_config(*config);

    std::call_once(backend_init_once, [] {
        llama_backend_init();
        ggml_backend_load_all();
    });

    llama_model_params model_params = llama_model_default_params();
#if TARGET_OS_WATCH || TARGET_OS_SIMULATOR
    model_params.n_gpu_layers = 0;
#else
    model_params.n_gpu_layers = generation_params.gpu_layers < 0 ? 999 : generation_params.gpu_layers;
#endif

    llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (!model) {
        return fail("无法加载本地模型权重。", error_message);
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    std::vector<llama_token> prompt_tokens = tokenize(vocab, prompt);
    if (prompt_tokens.empty()) {
        llama_model_free(model);
        return fail("本地模型无法解析提示词。", error_message);
    }

    const int32_t requested_context = std::max<int32_t>(1, generation_params.context_size);
    const int32_t requested_output = std::max<int32_t>(1, generation_params.max_output_tokens);
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

    llama_sampler * sampler = create_sampler(model, vocab, generation_params);
    if (!sampler) {
        llama_free(ctx);
        llama_model_free(model);
        return fail("无法创建本地模型采样器。", error_message);
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

        std::string piece = token_to_piece(vocab, token);
        if (piece.empty()) {
            llama_sampler_free(sampler);
            llama_free(ctx);
            llama_model_free(model);
            return fail("本地模型输出转换失败。", error_message);
        }

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
    const etos_local_llm_generation_config * config,
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
        config,
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
    const etos_local_llm_generation_config * config,
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
        config,
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
