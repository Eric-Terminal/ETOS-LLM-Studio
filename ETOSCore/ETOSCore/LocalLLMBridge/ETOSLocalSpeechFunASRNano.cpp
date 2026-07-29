// ============================================================================
// ETOSLocalSpeechFunASRNano.cpp
// ============================================================================
// ETOS LLM Studio
//
// 改编自 FunASR llama.cpp runtime v0.1.9（MIT）的 Fun-ASR-Nano 实现。
// ============================================================================

#include "ETOSLocalSpeechInternal.h"

#include <map>

namespace etos_local_speech {
namespace {

struct nano_encoder_config {
    int32_t model_dimension = 512;
    int32_t attention_heads = 4;
    int32_t encoder_blocks = 50;
    int32_t temporal_blocks = 20;
    int32_t kernel_size = 11;
    int32_t llm_dimension = 1024;
    int32_t adaptor_layers = 2;
    int32_t adaptor_heads = 8;
};

struct nano_encoder_model {
    nano_encoder_config config;
    ggml_context * weights_context = nullptr;
    std::map<std::string, ggml_tensor *> tensors;

    ~nano_encoder_model() {
        if (weights_context) {
            ggml_free(weights_context);
        }
    }

    ggml_tensor * required(const std::string & name) const {
        const auto iterator = tensors.find(name);
        if (iterator == tensors.end() || !iterator->second) {
            throw std::runtime_error("Fun-ASR-Nano 编码器缺少张量：" + name);
        }
        return iterator->second;
    }
};

std::mutex cache_mutex;
std::string cached_path;
std::shared_ptr<nano_encoder_model> cached_model;

void validate_encoder_layer(const nano_encoder_model & model, const std::string & prefix) {
    model.required(prefix + "norm1.weight");
    model.required(prefix + "norm1.bias");
    model.required(prefix + "self_attn.linear_q_k_v.weight");
    model.required(prefix + "self_attn.linear_q_k_v.bias");
    model.required(prefix + "self_attn.fsmn_block.weight");
    model.required(prefix + "self_attn.linear_out.weight");
    model.required(prefix + "self_attn.linear_out.bias");
    model.required(prefix + "norm2.weight");
    model.required(prefix + "norm2.bias");
    model.required(prefix + "feed_forward.w_1.weight");
    model.required(prefix + "feed_forward.w_1.bias");
    model.required(prefix + "feed_forward.w_2.weight");
    model.required(prefix + "feed_forward.w_2.bias");
}

void validate_adaptor_layer(const nano_encoder_model & model, const std::string & prefix) {
    model.required(prefix + "norm1.weight");
    model.required(prefix + "norm1.bias");
    model.required(prefix + "self_attn.linear_q.weight");
    model.required(prefix + "self_attn.linear_q.bias");
    model.required(prefix + "self_attn.linear_k.weight");
    model.required(prefix + "self_attn.linear_k.bias");
    model.required(prefix + "self_attn.linear_v.weight");
    model.required(prefix + "self_attn.linear_v.bias");
    model.required(prefix + "self_attn.linear_out.weight");
    model.required(prefix + "self_attn.linear_out.bias");
    model.required(prefix + "norm2.weight");
    model.required(prefix + "norm2.bias");
    model.required(prefix + "feed_forward.w_1.weight");
    model.required(prefix + "feed_forward.w_1.bias");
    model.required(prefix + "feed_forward.w_2.weight");
    model.required(prefix + "feed_forward.w_2.bias");
}

void validate_model(const nano_encoder_model & model) {
    model.required("audio_encoder.after_norm.weight");
    model.required("audio_encoder.after_norm.bias");
    model.required("audio_encoder.tp_norm.weight");
    model.required("audio_encoder.tp_norm.bias");
    model.required("audio_adaptor.linear1.weight");
    model.required("audio_adaptor.linear1.bias");
    model.required("audio_adaptor.linear2.weight");
    model.required("audio_adaptor.linear2.bias");
    validate_encoder_layer(model, "audio_encoder.encoders0.0.");
    for (int32_t index = 0; index < model.config.encoder_blocks - 1; ++index) {
        validate_encoder_layer(
            model,
            "audio_encoder.encoders." + std::to_string(index) + "."
        );
    }
    for (int32_t index = 0; index < model.config.temporal_blocks; ++index) {
        validate_encoder_layer(
            model,
            "audio_encoder.tp_encoders." + std::to_string(index) + "."
        );
    }
    for (int32_t index = 0; index < model.config.adaptor_layers; ++index) {
        validate_adaptor_layer(
            model,
            "audio_adaptor.blocks." + std::to_string(index) + "."
        );
    }
}

std::shared_ptr<nano_encoder_model> load_encoder(
    const std::string & path,
    bool use_cache
) {
    if (use_cache) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        if (cached_model && cached_path == path) {
            return cached_model;
        }
    }

    auto model = std::make_shared<nano_encoder_model>();
    gguf_init_params init_params = {false, &model->weights_context};
    gguf_context * gguf = gguf_init_from_file(path.c_str(), init_params);
    if (!gguf) {
        throw std::runtime_error("无法加载 Fun-ASR-Nano 编码器 GGUF。");
    }
    const auto read_integer = [&](const char * key, int32_t fallback) {
        const int64_t index = gguf_find_key(gguf, key);
        return index < 0 ? fallback : static_cast<int32_t>(gguf_get_val_u32(gguf, index));
    };
    model->config.model_dimension = read_integer("funasr.enc.output_size", 512);
    model->config.attention_heads = read_integer("funasr.enc.attention_heads", 4);
    model->config.encoder_blocks = read_integer("funasr.enc.num_blocks", 50);
    model->config.temporal_blocks = read_integer("funasr.enc.tp_blocks", 20);
    model->config.kernel_size = read_integer("funasr.enc.kernel_size", 11);
    model->config.llm_dimension = read_integer("funasr.adp.llm_dim", 1024);
    model->config.adaptor_layers = read_integer("funasr.adp.n_layer", 2);
    model->config.adaptor_heads = read_integer("funasr.adp.attention_heads", 8);
    for (int64_t index = 0; index < gguf_get_n_tensors(gguf); ++index) {
        const char * name = gguf_get_tensor_name(gguf, index);
        model->tensors[name] = ggml_get_tensor(model->weights_context, name);
    }
    gguf_free(gguf);
    validate_model(*model);

    if (use_cache) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        cached_path = path;
        cached_model = model;
    }
    return model;
}

ggml_tensor * encoder_attention(
    ggml_context * context,
    const nano_encoder_model & model,
    const std::string & prefix,
    ggml_tensor * input,
    int32_t frame_count
) {
    const int32_t dimension = model.config.model_dimension;
    const int32_t head_count = model.config.attention_heads;
    const int32_t head_dimension = dimension / head_count;
    ggml_tensor * qkv = linear(
        context,
        model.required(prefix + "linear_q_k_v.weight"),
        model.required(prefix + "linear_q_k_v.bias"),
        input
    );
    const size_t row_stride = qkv->nb[1];
    ggml_tensor * query = ggml_cont(
        context,
        ggml_view_2d(context, qkv, dimension, frame_count, row_stride, 0)
    );
    ggml_tensor * key = ggml_cont(
        context,
        ggml_view_2d(
            context,
            qkv,
            dimension,
            frame_count,
            row_stride,
            static_cast<size_t>(dimension) * sizeof(float)
        )
    );
    ggml_tensor * value = ggml_cont(
        context,
        ggml_view_2d(
            context,
            qkv,
            dimension,
            frame_count,
            row_stride,
            static_cast<size_t>(2 * dimension) * sizeof(float)
        )
    );
    const int32_t padding = (model.config.kernel_size - 1) / 2;
    ggml_tensor * kernel = model.required(prefix + "fsmn_block.weight");
    ggml_tensor * padded = ggml_pad_ext(
        context,
        value,
        0,
        0,
        padding,
        padding,
        0,
        0,
        0,
        0
    );
    ggml_tensor * memory = value;
    for (int32_t tap = 0; tap < model.config.kernel_size; ++tap) {
        ggml_tensor * slice = ggml_view_2d(
            context,
            padded,
            dimension,
            frame_count,
            padded->nb[1],
            static_cast<size_t>(tap) * padded->nb[1]
        );
        ggml_tensor * weight = ggml_view_1d(
            context,
            kernel,
            dimension,
            static_cast<size_t>(tap) * kernel->nb[1]
        );
        memory = ggml_add(
            context,
            memory,
            ggml_mul(context, ggml_cont(context, slice), weight)
        );
    }
    query = ggml_permute(
        context,
        ggml_reshape_3d(context, query, head_dimension, head_count, frame_count),
        0,
        2,
        1,
        3
    );
    key = ggml_permute(
        context,
        ggml_reshape_3d(context, key, head_dimension, head_count, frame_count),
        0,
        2,
        1,
        3
    );
    ggml_tensor * value_heads = ggml_cont(
        context,
        ggml_permute(
            context,
            ggml_reshape_3d(context, value, head_dimension, head_count, frame_count),
            1,
            2,
            0,
            3
        )
    );
    ggml_tensor * scores = ggml_soft_max(
        context,
        ggml_scale(
            context,
            ggml_mul_mat(context, key, query),
            1.0f / std::sqrt(static_cast<float>(head_dimension))
        )
    );
    ggml_tensor * output = ggml_cont_2d(
        context,
        ggml_permute(
            context,
            ggml_mul_mat(context, value_heads, scores),
            0,
            2,
            1,
            3
        ),
        dimension,
        frame_count
    );
    return ggml_add(
        context,
        linear(
            context,
            model.required(prefix + "linear_out.weight"),
            model.required(prefix + "linear_out.bias"),
            output
        ),
        memory
    );
}

ggml_tensor * encoder_layer(
    ggml_context * context,
    const nano_encoder_model & model,
    const std::string & prefix,
    ggml_tensor * input,
    int32_t frame_count,
    bool uses_attention_residual
) {
    ggml_tensor * residual = input;
    ggml_tensor * hidden = layer_norm(
        context,
        input,
        model.required(prefix + "norm1.weight"),
        model.required(prefix + "norm1.bias")
    );
    hidden = encoder_attention(
        context,
        model,
        prefix + "self_attn.",
        hidden,
        frame_count
    );
    input = uses_attention_residual ? ggml_add(context, residual, hidden) : hidden;
    residual = input;
    hidden = layer_norm(
        context,
        input,
        model.required(prefix + "norm2.weight"),
        model.required(prefix + "norm2.bias")
    );
    hidden = linear(
        context,
        model.required(prefix + "feed_forward.w_1.weight"),
        model.required(prefix + "feed_forward.w_1.bias"),
        hidden
    );
    hidden = ggml_relu(context, hidden);
    hidden = linear(
        context,
        model.required(prefix + "feed_forward.w_2.weight"),
        model.required(prefix + "feed_forward.w_2.bias"),
        hidden
    );
    return ggml_add(context, residual, hidden);
}

ggml_tensor * adaptor_layer(
    ggml_context * context,
    const nano_encoder_model & model,
    const std::string & prefix,
    ggml_tensor * input,
    int32_t frame_count
) {
    const int32_t dimension = model.config.llm_dimension;
    const int32_t head_count = model.config.adaptor_heads;
    const int32_t head_dimension = dimension / head_count;
    ggml_tensor * residual = input;
    ggml_tensor * hidden = layer_norm(
        context,
        input,
        model.required(prefix + "norm1.weight"),
        model.required(prefix + "norm1.bias")
    );
    ggml_tensor * query = linear(
        context,
        model.required(prefix + "self_attn.linear_q.weight"),
        model.required(prefix + "self_attn.linear_q.bias"),
        hidden
    );
    ggml_tensor * key = linear(
        context,
        model.required(prefix + "self_attn.linear_k.weight"),
        model.required(prefix + "self_attn.linear_k.bias"),
        hidden
    );
    ggml_tensor * value = linear(
        context,
        model.required(prefix + "self_attn.linear_v.weight"),
        model.required(prefix + "self_attn.linear_v.bias"),
        hidden
    );
    query = ggml_permute(
        context,
        ggml_reshape_3d(context, query, head_dimension, head_count, frame_count),
        0,
        2,
        1,
        3
    );
    key = ggml_permute(
        context,
        ggml_reshape_3d(context, key, head_dimension, head_count, frame_count),
        0,
        2,
        1,
        3
    );
    ggml_tensor * value_heads = ggml_cont(
        context,
        ggml_permute(
            context,
            ggml_reshape_3d(context, value, head_dimension, head_count, frame_count),
            1,
            2,
            0,
            3
        )
    );
    ggml_tensor * scores = ggml_soft_max(
        context,
        ggml_scale(
            context,
            ggml_mul_mat(context, key, query),
            1.0f / std::sqrt(static_cast<float>(head_dimension))
        )
    );
    ggml_tensor * output = ggml_cont_2d(
        context,
        ggml_permute(
            context,
            ggml_mul_mat(context, value_heads, scores),
            0,
            2,
            1,
            3
        ),
        dimension,
        frame_count
    );
    input = ggml_add(
        context,
        residual,
        linear(
            context,
            model.required(prefix + "self_attn.linear_out.weight"),
            model.required(prefix + "self_attn.linear_out.bias"),
            output
        )
    );
    residual = input;
    hidden = layer_norm(
        context,
        input,
        model.required(prefix + "norm2.weight"),
        model.required(prefix + "norm2.bias")
    );
    hidden = linear(
        context,
        model.required(prefix + "feed_forward.w_1.weight"),
        model.required(prefix + "feed_forward.w_1.bias"),
        hidden
    );
    hidden = ggml_relu(context, hidden);
    hidden = linear(
        context,
        model.required(prefix + "feed_forward.w_2.weight"),
        model.required(prefix + "feed_forward.w_2.bias"),
        hidden
    );
    return ggml_add(context, residual, hidden);
}

std::vector<float> run_encoder(
    const nano_encoder_model & model,
    std::vector<float> features,
    int32_t frame_count,
    int32_t & output_dimension,
    const transcription_options & options
) {
    const float scale = std::sqrt(static_cast<float>(model.config.model_dimension));
    for (float & value : features) {
        value *= scale;
    }
    add_positional_encoding(features, frame_count, feature_dimension);
    throw_if_cancelled(options);

    ggml_backend_t backend = ggml_backend_cpu_init();
    if (!backend) {
        throw std::runtime_error("无法初始化 Fun-ASR-Nano 编码器后端。");
    }
    ggml_init_params params = {
        static_cast<size_t>(256) * 1024 * 1024,
        nullptr,
        true
    };
    ggml_context * context = ggml_init(params);
    if (!context) {
        ggml_backend_free(backend);
        throw std::runtime_error("无法创建 Fun-ASR-Nano 编码器计算图。");
    }
    ggml_tensor * input = ggml_new_tensor_2d(
        context,
        GGML_TYPE_F32,
        feature_dimension,
        frame_count
    );
    ggml_set_input(input);
    ggml_tensor * hidden = encoder_layer(
        context,
        model,
        "audio_encoder.encoders0.0.",
        input,
        frame_count,
        false
    );
    for (int32_t index = 0; index < model.config.encoder_blocks - 1; ++index) {
        hidden = encoder_layer(
            context,
            model,
            "audio_encoder.encoders." + std::to_string(index) + ".",
            hidden,
            frame_count,
            true
        );
    }
    hidden = layer_norm(
        context,
        hidden,
        model.required("audio_encoder.after_norm.weight"),
        model.required("audio_encoder.after_norm.bias")
    );
    for (int32_t index = 0; index < model.config.temporal_blocks; ++index) {
        hidden = encoder_layer(
            context,
            model,
            "audio_encoder.tp_encoders." + std::to_string(index) + ".",
            hidden,
            frame_count,
            true
        );
    }
    hidden = layer_norm(
        context,
        hidden,
        model.required("audio_encoder.tp_norm.weight"),
        model.required("audio_encoder.tp_norm.bias")
    );
    hidden = linear(
        context,
        model.required("audio_adaptor.linear1.weight"),
        model.required("audio_adaptor.linear1.bias"),
        hidden
    );
    hidden = ggml_relu(context, hidden);
    hidden = linear(
        context,
        model.required("audio_adaptor.linear2.weight"),
        model.required("audio_adaptor.linear2.bias"),
        hidden
    );
    for (int32_t index = 0; index < model.config.adaptor_layers; ++index) {
        hidden = adaptor_layer(
            context,
            model,
            "audio_adaptor.blocks." + std::to_string(index) + ".",
            hidden,
            frame_count
        );
    }
    ggml_set_output(hidden);
    ggml_cgraph * graph = ggml_new_graph_custom(context, 32768, false);
    ggml_build_forward_expand(graph, hidden);
    ggml_gallocr_t allocator = ggml_gallocr_new(ggml_backend_cpu_buffer_type());
    ggml_gallocr_alloc_graph(allocator, graph);
    ggml_backend_tensor_set(input, features.data(), 0, ggml_nbytes(input));
    ggml_backend_cpu_set_n_threads(backend, options.threads);
    const bool computed = ggml_backend_graph_compute(backend, graph) == GGML_STATUS_SUCCESS;
    output_dimension = static_cast<int32_t>(hidden->ne[0]);
    std::vector<float> output(
        static_cast<size_t>(output_dimension) * frame_count
    );
    if (computed) {
        ggml_backend_tensor_get(hidden, output.data(), 0, ggml_nbytes(hidden));
    }
    ggml_gallocr_free(allocator);
    ggml_free(context);
    ggml_backend_free(backend);
    if (!computed) {
        throw std::runtime_error("Fun-ASR-Nano 音频编码失败。");
    }
    throw_if_cancelled(options);
    return output;
}

int32_t decode_batch(
    llama_context * context,
    int32_t count,
    llama_token * tokens,
    float * embeddings,
    int32_t embedding_dimension,
    int32_t & past_count,
    bool requests_logits
) {
    std::vector<llama_pos> positions(count);
    std::vector<int32_t> sequence_counts(count, 1);
    std::vector<llama_seq_id> sequence_zero(1, 0);
    std::vector<llama_seq_id *> sequence_ids(count);
    std::vector<int8_t> logits(count, 0);
    for (int32_t index = 0; index < count; ++index) {
        positions[index] = past_count + index;
        sequence_ids[index] = sequence_zero.data();
    }
    if (requests_logits) {
        logits[count - 1] = 1;
    }
    llama_batch batch = {
        count,
        tokens,
        embeddings,
        positions.data(),
        sequence_counts.data(),
        sequence_ids.data(),
        logits.data()
    };
    const int32_t status = llama_decode(context, batch);
    if (status == 0) {
        past_count += count;
    }
    return status;
}

std::vector<llama_token> tokenize(
    const llama_vocab * vocabulary,
    const std::string & text
) {
    const int32_t required = -llama_tokenize(
        vocabulary,
        text.c_str(),
        static_cast<int32_t>(text.size()),
        nullptr,
        0,
        false,
        true
    );
    if (required <= 0) {
        throw std::runtime_error("Fun-ASR-Nano 提示词分词失败。");
    }
    std::vector<llama_token> tokens(required);
    const int32_t count = llama_tokenize(
        vocabulary,
        text.c_str(),
        static_cast<int32_t>(text.size()),
        tokens.data(),
        required,
        false,
        true
    );
    if (count < 0) {
        throw std::runtime_error("Fun-ASR-Nano 提示词分词失败。");
    }
    tokens.resize(count);
    return tokens;
}

std::vector<speech_segment> nano_segments(
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    if (!options.vad_model_path.empty()) {
        return speech_segments(waveform, options);
    }
    const int32_t chunk_samples = std::max(
        sample_rate,
        options.chunk_seconds * sample_rate
    );
    std::vector<speech_segment> segments;
    for (int32_t offset = 0; offset < static_cast<int32_t>(waveform.size());
         offset += chunk_samples) {
        segments.push_back({
            offset,
            std::min(
                static_cast<int32_t>(waveform.size()),
                offset + chunk_samples
            )
        });
    }
    return segments;
}

} // namespace

std::string transcribe_fun_asr_nano(
    const std::string & encoder_model_path,
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    if (options.decoder_model_path.empty()) {
        throw std::runtime_error("Fun-ASR-Nano 需要关联 Qwen3 解码 GGUF。");
    }
    const std::shared_ptr<nano_encoder_model> encoder = load_encoder(
        encoder_model_path,
        options.use_model_cache
    );
    std::call_once(etos_local_llm_bridge::backend_init_once, [] {
        ggml_backend_load_all();
    });
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = options.gpu_layers;
    const etos_local_llm_bridge::llama_model_shared_handle decoder =
        etos_local_llm_bridge::load_model(
            options.decoder_model_path.c_str(),
            model_params,
            options.use_model_cache
        );
    if (!decoder) {
        throw std::runtime_error("无法加载 Fun-ASR-Nano 的 Qwen3 解码模型。");
    }
    if (llama_model_n_embd(decoder.get()) != encoder->config.llm_dimension) {
        throw std::runtime_error("Fun-ASR-Nano 编码器与解码模型的嵌入维度不匹配。");
    }
    const llama_vocab * vocabulary = llama_model_get_vocab(decoder.get());
    if (!vocabulary) {
        throw std::runtime_error("Fun-ASR-Nano 解码模型缺少词表。");
    }

    llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = static_cast<uint32_t>(std::max(512, options.context_size));
    context_params.n_batch = std::min<uint32_t>(context_params.n_ctx, 2048);
    context_params.n_ubatch = context_params.n_batch;
    etos_local_llm_bridge::llama_context_handle context(
        llama_init_from_model(decoder.get(), context_params)
    );
    if (!context) {
        throw std::runtime_error("无法创建 Fun-ASR-Nano 解码上下文。");
    }

    const std::vector<llama_token> prefix = tokenize(
        vocabulary,
        "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n"
        "<|im_start|>user\n语音转写："
    );
    const std::vector<llama_token> suffix = tokenize(
        vocabulary,
        "<|im_end|>\n<|im_start|>assistant\n"
    );
    const std::vector<speech_segment> segments = nano_segments(waveform, options);
    std::string result;
    for (const speech_segment & segment : segments) {
        throw_if_cancelled(options);
        if (segment.second - segment.first < window_length) {
            continue;
        }
        const std::vector<float> samples(
            waveform.begin() + segment.first,
            waveform.begin() + segment.second
        );
        int32_t feature_frames = 0;
        std::vector<float> features = compute_fbank(samples, feature_frames);
        if (feature_frames == 0) {
            continue;
        }
        int32_t embedding_dimension = 0;
        std::vector<float> audio_embeddings = run_encoder(
            *encoder,
            std::move(features),
            feature_frames,
            embedding_dimension,
            options
        );
        const int32_t first_downsample = 1 + (feature_frames - 3 + 2) / 2;
        const int32_t second_downsample = 1 + (first_downsample - 3 + 2) / 2;
        const int32_t audio_token_count = (second_downsample - 1) / 2 + 1;
        const int32_t required_context = static_cast<int32_t>(
            prefix.size() + suffix.size()
        ) + audio_token_count + options.max_output_tokens;
        if (required_context > static_cast<int32_t>(context_params.n_ctx)) {
            throw std::runtime_error("Fun-ASR-Nano 上下文不足，请增大本地模型上下文长度。");
        }

        llama_memory_clear(llama_get_memory(context.get()), true);
        int32_t past_count = 0;
        if (decode_batch(
                context.get(),
                static_cast<int32_t>(prefix.size()),
                const_cast<llama_token *>(prefix.data()),
                nullptr,
                0,
                past_count,
                false
            ) != 0
            || decode_batch(
                context.get(),
                audio_token_count,
                nullptr,
                audio_embeddings.data(),
                embedding_dimension,
                past_count,
                false
            ) != 0
            || decode_batch(
                context.get(),
                static_cast<int32_t>(suffix.size()),
                const_cast<llama_token *>(suffix.data()),
                nullptr,
                0,
                past_count,
                true
            ) != 0) {
            throw std::runtime_error("Fun-ASR-Nano 音频提示解码失败。");
        }

        const auto sampler_params = llama_sampler_chain_default_params();
        etos_local_llm_bridge::llama_sampler_handle sampler(
            llama_sampler_chain_init(sampler_params)
        );
        if (!sampler) {
            throw std::runtime_error("无法创建 Fun-ASR-Nano 采样器。");
        }
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
        std::string segment_text;
        llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
        for (int32_t index = 0; index < options.max_output_tokens; ++index) {
            throw_if_cancelled(options);
            if (llama_vocab_is_eog(vocabulary, token)) {
                break;
            }
            segment_text += etos_local_llm_bridge::token_to_piece(vocabulary, token);
            if (decode_batch(
                    context.get(),
                    1,
                    &token,
                    nullptr,
                    0,
                    past_count,
                    true
                ) != 0) {
                throw std::runtime_error("Fun-ASR-Nano 文本解码失败。");
            }
            token = llama_sampler_sample(sampler.get(), context.get(), -1);
        }
        append_segment_text(result, segment_text);
    }
    return result;
}

void clear_fun_asr_nano_cache() {
    std::lock_guard<std::mutex> lock(cache_mutex);
    cached_model.reset();
    cached_path.clear();
}

} // namespace etos_local_speech
