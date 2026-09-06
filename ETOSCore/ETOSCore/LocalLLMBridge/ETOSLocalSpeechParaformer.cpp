// ============================================================================
// ETOSLocalSpeechParaformer.cpp
// ============================================================================
// ETOS LLM Studio
//
// 改编自 FunASR llama.cpp runtime v0.1.9（MIT）的 Paraformer 实现。
// ============================================================================

#include "ETOSLocalSpeechInternal.h"

#include <map>

namespace etos_local_speech {
namespace {

struct paraformer_config {
    int32_t model_dimension = 512;
    int32_t encoder_heads = 4;
    int32_t encoder_blocks = 50;
    int32_t encoder_kernel = 11;
    int32_t decoder_blocks = 16;
    int32_t decoder_attention_blocks = 16;
    int32_t decoder_final_blocks = 1;
    int32_t decoder_heads = 4;
    int32_t decoder_kernel = 11;
    int32_t vocabulary_size = 8404;
    float predictor_tail_threshold = 0.45f;
    float predictor_threshold = 1.0f;
};

struct paraformer_model {
    paraformer_config config;
    ggml_context * weights_context = nullptr;
    std::map<std::string, ggml_tensor *> tensors;
    std::vector<std::string> vocabulary;

    ~paraformer_model() {
        if (weights_context) {
            ggml_free(weights_context);
        }
    }

    ggml_tensor * required(const std::string & name) const {
        const auto iterator = tensors.find(name);
        if (iterator == tensors.end() || !iterator->second) {
            throw std::runtime_error("Paraformer 模型缺少张量：" + name);
        }
        return iterator->second;
    }
};

std::mutex cache_mutex;
std::string cached_path;
std::shared_ptr<paraformer_model> cached_model;

void validate_encoder_layer(const paraformer_model & model, const std::string & prefix) {
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

void validate_decoder_layer(const paraformer_model & model, const std::string & prefix) {
    model.required(prefix + "norm1.weight");
    model.required(prefix + "norm1.bias");
    model.required(prefix + "feed_forward.w_1.weight");
    model.required(prefix + "feed_forward.w_1.bias");
    model.required(prefix + "feed_forward.norm.weight");
    model.required(prefix + "feed_forward.norm.bias");
    model.required(prefix + "feed_forward.w_2.weight");
    model.required(prefix + "norm2.weight");
    model.required(prefix + "norm2.bias");
    model.required(prefix + "self_attn.fsmn_block.weight");
    model.required(prefix + "norm3.weight");
    model.required(prefix + "norm3.bias");
    model.required(prefix + "src_attn.linear_q.weight");
    model.required(prefix + "src_attn.linear_q.bias");
    model.required(prefix + "src_attn.linear_k_v.weight");
    model.required(prefix + "src_attn.linear_k_v.bias");
    model.required(prefix + "src_attn.linear_out.weight");
    model.required(prefix + "src_attn.linear_out.bias");
}

void validate_model(const paraformer_model & model) {
    model.required("cmvn.shift");
    model.required("cmvn.scale");
    model.required("encoder.after_norm.weight");
    model.required("encoder.after_norm.bias");
    model.required("predictor.cif_conv1d.weight");
    model.required("predictor.cif_conv1d.bias");
    model.required("predictor.cif_output.weight");
    model.required("predictor.cif_output.bias");
    model.required("decoder.after_norm.weight");
    model.required("decoder.after_norm.bias");
    model.required("decoder.output_layer.weight");
    model.required("decoder.output_layer.bias");
    validate_encoder_layer(model, "encoder.encoders0.0.");
    for (int32_t index = 0; index < model.config.encoder_blocks - 1; ++index) {
        validate_encoder_layer(model, "encoder.encoders." + std::to_string(index) + ".");
    }
    for (int32_t index = 0; index < model.config.decoder_attention_blocks; ++index) {
        validate_decoder_layer(model, "decoder.decoders." + std::to_string(index) + ".");
    }
    for (int32_t index = 0; index < model.config.decoder_final_blocks; ++index) {
        const std::string prefix = "decoder.decoders3." + std::to_string(index) + ".";
        model.required(prefix + "norm1.weight");
        model.required(prefix + "norm1.bias");
        model.required(prefix + "feed_forward.w_1.weight");
        model.required(prefix + "feed_forward.w_1.bias");
        model.required(prefix + "feed_forward.norm.weight");
        model.required(prefix + "feed_forward.norm.bias");
        model.required(prefix + "feed_forward.w_2.weight");
    }
}

std::shared_ptr<paraformer_model> load_model(
    const std::string & path,
    bool use_cache
) {
    if (use_cache) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        if (cached_model && cached_path == path) {
            return cached_model;
        }
    }

    auto model = std::make_shared<paraformer_model>();
    gguf_init_params init_params = {false, &model->weights_context};
    gguf_context * gguf = gguf_init_from_file(path.c_str(), init_params);
    if (!gguf) {
        throw std::runtime_error("无法加载 Paraformer GGUF 模型。");
    }
    const auto read_integer = [&](const char * key, int32_t fallback) {
        const int64_t index = gguf_find_key(gguf, key);
        return index < 0 ? fallback : static_cast<int32_t>(gguf_get_val_u32(gguf, index));
    };
    const auto read_float = [&](const char * key, float fallback) {
        const int64_t index = gguf_find_key(gguf, key);
        return index < 0 ? fallback : gguf_get_val_f32(gguf, index);
    };
    model->config.encoder_blocks = read_integer("pf.enc.num_blocks", 50);
    model->config.decoder_blocks = read_integer("pf.dec.num_blocks", 16);
    model->config.decoder_attention_blocks = read_integer("pf.dec.att_layer_num", 16);
    model->config.decoder_final_blocks = read_integer("pf.dec.decoders3", 1);
    model->config.vocabulary_size = read_integer("pf.vocab_size", 8404);
    model->config.predictor_tail_threshold = read_float(
        "pf.predictor.tail_threshold",
        0.45f
    );
    model->config.predictor_threshold = read_float("pf.predictor.threshold", 1.0f);
    const int64_t vocabulary_key = gguf_find_key(gguf, "pf.vocab");
    if (vocabulary_key >= 0) {
        const size_t count = gguf_get_arr_n(gguf, vocabulary_key);
        model->vocabulary.reserve(count);
        for (size_t index = 0; index < count; ++index) {
            const char * token = gguf_get_arr_str(gguf, vocabulary_key, index);
            model->vocabulary.emplace_back(token ? token : "");
        }
    }
    for (int64_t index = 0; index < gguf_get_n_tensors(gguf); ++index) {
        const char * name = gguf_get_tensor_name(gguf, index);
        model->tensors[name] = ggml_get_tensor(model->weights_context, name);
    }
    gguf_free(gguf);
    if (model->vocabulary.empty()) {
        throw std::runtime_error("Paraformer GGUF 未内嵌词表，无法直接输出文本。");
    }
    validate_model(*model);

    if (use_cache) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        cached_path = path;
        cached_model = model;
    }
    return model;
}

ggml_tensor * fsmn(
    ggml_context * context,
    ggml_tensor * input,
    ggml_tensor * kernel,
    int32_t dimension,
    int32_t frame_count,
    int32_t kernel_size
) {
    const int32_t padding = (kernel_size - 1) / 2;
    ggml_tensor * padded = ggml_pad_ext(
        context,
        input,
        0,
        0,
        padding,
        padding,
        0,
        0,
        0,
        0
    );
    ggml_tensor * result = input;
    for (int32_t tap = 0; tap < kernel_size; ++tap) {
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
        result = ggml_add(
            context,
            result,
            ggml_mul(context, ggml_cont(context, slice), weight)
        );
    }
    return result;
}

ggml_tensor * encoder_attention(
    ggml_context * context,
    const paraformer_model & model,
    const std::string & prefix,
    ggml_tensor * input,
    int32_t frame_count
) {
    const int32_t dimension = model.config.model_dimension;
    const int32_t head_count = model.config.encoder_heads;
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
    ggml_tensor * memory = fsmn(
        context,
        value,
        model.required(prefix + "fsmn_block.weight"),
        dimension,
        frame_count,
        model.config.encoder_kernel
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
    const paraformer_model & model,
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

ggml_tensor * decoder_feed_forward(
    ggml_context * context,
    const paraformer_model & model,
    const std::string & prefix,
    ggml_tensor * input
) {
    ggml_tensor * hidden = linear(
        context,
        model.required(prefix + "w_1.weight"),
        model.required(prefix + "w_1.bias"),
        input
    );
    hidden = ggml_relu(context, hidden);
    hidden = layer_norm(
        context,
        hidden,
        model.required(prefix + "norm.weight"),
        model.required(prefix + "norm.bias")
    );
    return ggml_mul_mat(context, model.required(prefix + "w_2.weight"), hidden);
}

ggml_tensor * cross_attention(
    ggml_context * context,
    const paraformer_model & model,
    const std::string & prefix,
    ggml_tensor * target,
    ggml_tensor * memory,
    int32_t token_count,
    int32_t frame_count
) {
    const int32_t dimension = model.config.model_dimension;
    const int32_t head_count = model.config.decoder_heads;
    const int32_t head_dimension = dimension / head_count;
    ggml_tensor * query = linear(
        context,
        model.required(prefix + "linear_q.weight"),
        model.required(prefix + "linear_q.bias"),
        target
    );
    ggml_tensor * key_value = linear(
        context,
        model.required(prefix + "linear_k_v.weight"),
        model.required(prefix + "linear_k_v.bias"),
        memory
    );
    const size_t row_stride = key_value->nb[1];
    ggml_tensor * key = ggml_cont(
        context,
        ggml_view_2d(context, key_value, dimension, frame_count, row_stride, 0)
    );
    ggml_tensor * value = ggml_cont(
        context,
        ggml_view_2d(
            context,
            key_value,
            dimension,
            frame_count,
            row_stride,
            static_cast<size_t>(dimension) * sizeof(float)
        )
    );
    query = ggml_permute(
        context,
        ggml_reshape_3d(context, query, head_dimension, head_count, token_count),
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
        token_count
    );
    return linear(
        context,
        model.required(prefix + "linear_out.weight"),
        model.required(prefix + "linear_out.bias"),
        output
    );
}

ggml_tensor * decoder_layer(
    ggml_context * context,
    const paraformer_model & model,
    const std::string & prefix,
    ggml_tensor * target,
    ggml_tensor * memory,
    int32_t token_count,
    int32_t frame_count
) {
    ggml_tensor * residual = target;
    ggml_tensor * hidden = layer_norm(
        context,
        target,
        model.required(prefix + "norm1.weight"),
        model.required(prefix + "norm1.bias")
    );
    hidden = decoder_feed_forward(context, model, prefix + "feed_forward.", hidden);
    ggml_tensor * normalized = layer_norm(
        context,
        hidden,
        model.required(prefix + "norm2.weight"),
        model.required(prefix + "norm2.bias")
    );
    ggml_tensor * self_attention = fsmn(
        context,
        normalized,
        model.required(prefix + "self_attn.fsmn_block.weight"),
        model.config.model_dimension,
        token_count,
        model.config.decoder_kernel
    );
    target = ggml_add(context, residual, self_attention);
    residual = target;
    normalized = layer_norm(
        context,
        target,
        model.required(prefix + "norm3.weight"),
        model.required(prefix + "norm3.bias")
    );
    ggml_tensor * source_attention = cross_attention(
        context,
        model,
        prefix + "src_attn.",
        normalized,
        memory,
        token_count,
        frame_count
    );
    return ggml_add(context, residual, source_attention);
}

std::vector<float> run_graph(
    ggml_context * context,
    ggml_tensor * output,
    ggml_tensor * first_input,
    const float * first_values,
    ggml_tensor * second_input,
    const float * second_values,
    int32_t threads
) {
    ggml_backend_t backend = ggml_backend_cpu_init();
    if (!backend) {
        throw std::runtime_error("无法初始化 Paraformer CPU 后端。");
    }
    ggml_cgraph * graph = ggml_new_graph_custom(context, 32768, false);
    ggml_build_forward_expand(graph, output);
    ggml_gallocr_t allocator = ggml_gallocr_new(ggml_backend_cpu_buffer_type());
    ggml_gallocr_alloc_graph(allocator, graph);
    ggml_backend_tensor_set(first_input, first_values, 0, ggml_nbytes(first_input));
    if (second_input) {
        ggml_backend_tensor_set(second_input, second_values, 0, ggml_nbytes(second_input));
    }
    ggml_backend_cpu_set_n_threads(backend, threads);
    const bool computed = ggml_backend_graph_compute(backend, graph) == GGML_STATUS_SUCCESS;
    std::vector<float> result(
        static_cast<size_t>(output->ne[0]) * output->ne[1]
    );
    if (computed) {
        ggml_backend_tensor_get(output, result.data(), 0, ggml_nbytes(output));
    }
    ggml_gallocr_free(allocator);
    ggml_backend_free(backend);
    if (!computed) {
        throw std::runtime_error("Paraformer 推理失败。");
    }
    return result;
}

std::string detokenize(
    const std::vector<int32_t> & token_ids,
    const std::vector<std::string> & vocabulary
) {
    std::string result;
    for (const int32_t token_id : token_ids) {
        if (token_id == 1 || token_id == 2) {
            continue;
        }
        if (token_id >= 0 && token_id < static_cast<int32_t>(vocabulary.size())) {
            result += vocabulary[token_id];
        }
    }
    size_t position;
    while ((position = result.find("@@")) != std::string::npos) {
        result.erase(position, 2);
    }
    const std::string sentence_piece_space = "\xe2\x96\x81";
    while ((position = result.find(sentence_piece_space)) != std::string::npos) {
        result.replace(position, sentence_piece_space.size(), " ");
    }
    return trimmed(result);
}

std::string transcribe_segment(
    const paraformer_model & model,
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    int32_t frame_count = 0;
    std::vector<float> features = compute_fbank(waveform, frame_count);
    if (frame_count == 0) {
        return {};
    }
    float * shift = static_cast<float *>(model.required("cmvn.shift")->data);
    float * scale = static_cast<float *>(model.required("cmvn.scale")->data);
    for (int32_t time = 0; time < frame_count; ++time) {
        for (int32_t dimension = 0; dimension < feature_dimension; ++dimension) {
            const size_t offset = static_cast<size_t>(time) * feature_dimension + dimension;
            features[offset] = (features[offset] + shift[dimension]) * scale[dimension];
        }
    }
    const float model_scale = std::sqrt(static_cast<float>(model.config.model_dimension));
    for (float & value : features) {
        value *= model_scale;
    }
    add_positional_encoding(features, frame_count, feature_dimension);
    throw_if_cancelled(options);

    std::vector<float> encoder_output;
    {
        ggml_init_params params = {
            static_cast<size_t>(192) * 1024 * 1024,
            nullptr,
            true
        };
        ggml_context * context = ggml_init(params);
        if (!context) {
            throw std::runtime_error("无法创建 Paraformer 编码器计算图。");
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
            "encoder.encoders0.0.",
            input,
            frame_count,
            false
        );
        for (int32_t index = 0; index < model.config.encoder_blocks - 1; ++index) {
            hidden = encoder_layer(
                context,
                model,
                "encoder.encoders." + std::to_string(index) + ".",
                hidden,
                frame_count,
                true
            );
        }
        hidden = layer_norm(
            context,
            hidden,
            model.required("encoder.after_norm.weight"),
            model.required("encoder.after_norm.bias")
        );
        ggml_set_output(hidden);
        encoder_output = run_graph(
            context,
            hidden,
            input,
            features.data(),
            nullptr,
            nullptr,
            options.threads
        );
        ggml_free(context);
    }
    throw_if_cancelled(options);

    const int32_t dimension = model.config.model_dimension;
    float * convolution_weights = static_cast<float *>(
        model.required("predictor.cif_conv1d.weight")->data
    );
    float * convolution_bias = static_cast<float *>(
        model.required("predictor.cif_conv1d.bias")->data
    );
    float * output_weights = static_cast<float *>(
        model.required("predictor.cif_output.weight")->data
    );
    const float output_bias = static_cast<float *>(
        model.required("predictor.cif_output.bias")->data
    )[0];
    std::vector<float> predictor_output(
        static_cast<size_t>(frame_count) * dimension
    );
    std::vector<float> alpha(frame_count);
    for (int32_t time = 0; time < frame_count; ++time) {
        for (int32_t output = 0; output < dimension; ++output) {
            float accumulated = convolution_bias[output];
            for (int32_t tap = 0; tap < 3; ++tap) {
                const int32_t source_time = time + tap - 1;
                if (source_time < 0 || source_time >= frame_count) {
                    continue;
                }
                const float * source = encoder_output.data()
                    + static_cast<size_t>(source_time) * dimension;
                const float * weights = convolution_weights
                    + static_cast<size_t>(output) * dimension * 3;
                for (int32_t input = 0; input < dimension; ++input) {
                    accumulated += weights[input * 3 + tap] * source[input];
                }
            }
            predictor_output[static_cast<size_t>(time) * dimension + output]
                = accumulated + encoder_output[static_cast<size_t>(time) * dimension + output];
        }
        float value = output_bias;
        for (int32_t output = 0; output < dimension; ++output) {
            value += output_weights[output] * std::max(
                0.0f,
                predictor_output[static_cast<size_t>(time) * dimension + output]
            );
        }
        alpha[time] = std::max(0.0f, 1.0f / (1.0f + std::exp(-value)));
    }

    std::vector<float> hidden = encoder_output;
    hidden.resize(static_cast<size_t>(frame_count + 1) * dimension, 0.0f);
    alpha.push_back(model.config.predictor_tail_threshold);
    std::vector<float> acoustic_embeddings;
    float integration = 0.0f;
    std::vector<float> current_frame(dimension, 0.0f);
    for (int32_t time = 0; time <= frame_count; ++time) {
        const float current_alpha = alpha[time];
        const float required = 1.0f - integration;
        integration += current_alpha;
        const bool fires = integration >= model.config.predictor_threshold;
        const float current_weight = fires ? required : current_alpha;
        const float remaining_weight = current_alpha - current_weight;
        for (int32_t index = 0; index < dimension; ++index) {
            current_frame[index] += current_weight
                * hidden[static_cast<size_t>(time) * dimension + index];
        }
        if (fires) {
            acoustic_embeddings.insert(
                acoustic_embeddings.end(),
                current_frame.begin(),
                current_frame.end()
            );
            integration -= 1.0f;
            for (int32_t index = 0; index < dimension; ++index) {
                current_frame[index] = remaining_weight
                    * hidden[static_cast<size_t>(time) * dimension + index];
            }
        }
    }
    const int32_t token_count = static_cast<int32_t>(
        acoustic_embeddings.size() / dimension
    );
    if (token_count == 0) {
        return {};
    }

    std::vector<float> logits;
    {
        ggml_init_params params = {
            static_cast<size_t>(256) * 1024 * 1024,
            nullptr,
            true
        };
        ggml_context * context = ggml_init(params);
        if (!context) {
            throw std::runtime_error("无法创建 Paraformer 解码器计算图。");
        }
        ggml_tensor * target = ggml_new_tensor_2d(
            context,
            GGML_TYPE_F32,
            dimension,
            token_count
        );
        ggml_set_input(target);
        ggml_tensor * memory = ggml_new_tensor_2d(
            context,
            GGML_TYPE_F32,
            dimension,
            frame_count
        );
        ggml_set_input(memory);
        ggml_tensor * output = target;
        for (int32_t index = 0; index < model.config.decoder_attention_blocks; ++index) {
            output = decoder_layer(
                context,
                model,
                "decoder.decoders." + std::to_string(index) + ".",
                output,
                memory,
                token_count,
                frame_count
            );
        }
        for (int32_t index = 0; index < model.config.decoder_final_blocks; ++index) {
            const std::string prefix = "decoder.decoders3." + std::to_string(index) + ".";
            output = layer_norm(
                context,
                output,
                model.required(prefix + "norm1.weight"),
                model.required(prefix + "norm1.bias")
            );
            output = decoder_feed_forward(
                context,
                model,
                prefix + "feed_forward.",
                output
            );
        }
        output = layer_norm(
            context,
            output,
            model.required("decoder.after_norm.weight"),
            model.required("decoder.after_norm.bias")
        );
        output = linear(
            context,
            model.required("decoder.output_layer.weight"),
            model.required("decoder.output_layer.bias"),
            output
        );
        ggml_set_output(output);
        logits = run_graph(
            context,
            output,
            target,
            acoustic_embeddings.data(),
            memory,
            encoder_output.data(),
            options.threads
        );
        ggml_free(context);
    }
    throw_if_cancelled(options);

    std::vector<int32_t> token_ids;
    token_ids.reserve(token_count);
    for (int32_t time = 0; time < token_count; ++time) {
        const float * column = logits.data()
            + static_cast<size_t>(time) * model.config.vocabulary_size;
        int32_t maximum_index = 0;
        float maximum_value = column[0];
        for (int32_t index = 1; index < model.config.vocabulary_size; ++index) {
            if (column[index] > maximum_value) {
                maximum_value = column[index];
                maximum_index = index;
            }
        }
        token_ids.push_back(maximum_index);
    }
    return detokenize(token_ids, model.vocabulary);
}

} // namespace

std::string transcribe_paraformer(
    const std::string & model_path,
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    const std::shared_ptr<paraformer_model> model = load_model(
        model_path,
        options.use_model_cache
    );
    const std::vector<speech_segment> segments = speech_segments(waveform, options);
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
        append_segment_text(result, transcribe_segment(*model, samples, options));
    }
    return result;
}

void clear_paraformer_cache() {
    std::lock_guard<std::mutex> lock(cache_mutex);
    cached_model.reset();
    cached_path.clear();
}

} // namespace etos_local_speech
