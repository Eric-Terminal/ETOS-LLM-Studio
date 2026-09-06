// ============================================================================
// ETOSLocalSpeechSenseVoice.cpp
// ============================================================================
// ETOS LLM Studio
//
// 改编自 FunASR llama.cpp runtime v0.1.9（MIT）的 SenseVoiceSmall 实现。
// ============================================================================

#include "ETOSLocalSpeechInternal.h"

#include <cstring>
#include <map>

namespace etos_local_speech {
namespace {

struct sense_voice_config {
    int32_t model_dimension = 512;
    int32_t attention_heads = 4;
    int32_t encoder_blocks = 50;
    int32_t temporal_blocks = 20;
    int32_t kernel_size = 11;
    int32_t vocabulary_size = 25055;
    int32_t blank_token = 0;
};

struct sense_voice_model {
    sense_voice_config config;
    ggml_context * weights_context = nullptr;
    std::map<std::string, ggml_tensor *> tensors;
    std::vector<int32_t> query_tokens;
    std::vector<std::string> vocabulary;

    ~sense_voice_model() {
        if (weights_context) {
            ggml_free(weights_context);
        }
    }

    ggml_tensor * required(const std::string & name) const {
        const auto iterator = tensors.find(name);
        if (iterator == tensors.end() || !iterator->second) {
            throw std::runtime_error("SenseVoice 模型缺少张量：" + name);
        }
        return iterator->second;
    }
};

std::mutex cache_mutex;
std::string cached_path;
std::shared_ptr<sense_voice_model> cached_model;

void validate_model(const sense_voice_model & model) {
    model.required("embed.weight");
    model.required("encoder.after_norm.weight");
    model.required("encoder.after_norm.bias");
    model.required("encoder.tp_norm.weight");
    model.required("encoder.tp_norm.bias");
    model.required("ctc.ctc_lo.weight");
    model.required("ctc.ctc_lo.bias");
    const auto validate_layer = [&](const std::string & prefix) {
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
    };
    validate_layer("encoder.encoders0.0.");
    for (int32_t index = 0; index < model.config.encoder_blocks - 1; ++index) {
        validate_layer("encoder.encoders." + std::to_string(index) + ".");
    }
    for (int32_t index = 0; index < model.config.temporal_blocks; ++index) {
        validate_layer("encoder.tp_encoders." + std::to_string(index) + ".");
    }
}

std::shared_ptr<sense_voice_model> load_model(
    const std::string & path,
    bool use_cache
) {
    if (use_cache) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        if (cached_model && cached_path == path) {
            return cached_model;
        }
    }

    auto model = std::make_shared<sense_voice_model>();
    gguf_init_params init_params = {false, &model->weights_context};
    gguf_context * gguf = gguf_init_from_file(path.c_str(), init_params);
    if (!gguf) {
        throw std::runtime_error("无法加载 SenseVoice GGUF 模型。");
    }
    const auto read_integer = [&](const char * key, int32_t fallback) {
        const int64_t index = gguf_find_key(gguf, key);
        return index < 0 ? fallback : static_cast<int32_t>(gguf_get_val_u32(gguf, index));
    };
    model->config.model_dimension = read_integer("sv.output_size", 512);
    model->config.attention_heads = read_integer("sv.attention_heads", 4);
    model->config.encoder_blocks = read_integer("sv.num_blocks", 50);
    model->config.temporal_blocks = read_integer("sv.tp_blocks", 20);
    model->config.kernel_size = read_integer("sv.kernel_size", 11);
    model->config.vocabulary_size = read_integer("sv.vocab_size", 25055);
    model->config.blank_token = read_integer("sv.blank_id", 0);

    const int64_t query_key = gguf_find_key(gguf, "sv.query_tokens");
    if (query_key >= 0) {
        const size_t count = gguf_get_arr_n(gguf, query_key);
        const int32_t * tokens = static_cast<const int32_t *>(gguf_get_arr_data(gguf, query_key));
        model->query_tokens.assign(tokens, tokens + count);
    }
    const int64_t vocabulary_key = gguf_find_key(gguf, "sv.vocab");
    if (vocabulary_key >= 0) {
        const size_t count = gguf_get_arr_n(gguf, vocabulary_key);
        model->vocabulary.reserve(count);
        for (size_t index = 0; index < count; ++index) {
            const char * piece = gguf_get_arr_str(gguf, vocabulary_key, index);
            model->vocabulary.emplace_back(piece ? piece : "");
        }
    }
    for (int64_t index = 0; index < gguf_get_n_tensors(gguf); ++index) {
        const char * name = gguf_get_tensor_name(gguf, index);
        model->tensors[name] = ggml_get_tensor(model->weights_context, name);
    }
    gguf_free(gguf);

    if (model->query_tokens.empty()) {
        throw std::runtime_error("SenseVoice GGUF 缺少查询 token。");
    }
    if (model->vocabulary.empty()) {
        throw std::runtime_error("SenseVoice GGUF 未内嵌词表，无法直接输出文本。");
    }
    if (model->required("embed.weight")->type != GGML_TYPE_F32) {
        throw std::runtime_error("SenseVoice 查询嵌入必须保持 F32。");
    }
    validate_model(*model);

    if (use_cache) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        cached_path = path;
        cached_model = model;
    }
    return model;
}

ggml_tensor * self_attention(
    ggml_context * context,
    const sense_voice_model & model,
    const std::string & prefix,
    ggml_tensor * input,
    int32_t frame_count
) {
    const int32_t dimension = model.config.model_dimension;
    const int32_t head_count = model.config.attention_heads;
    const int32_t head_dimension = dimension / head_count;
    const int32_t kernel_size = model.config.kernel_size;
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

    const int32_t padding = (kernel_size - 1) / 2;
    ggml_tensor * kernel = model.required(prefix + "fsmn_block.weight");
    ggml_tensor * padded_value = ggml_pad_ext(
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
    for (int32_t tap = 0; tap < kernel_size; ++tap) {
        ggml_tensor * slice = ggml_view_2d(
            context,
            padded_value,
            dimension,
            frame_count,
            padded_value->nb[1],
            static_cast<size_t>(tap) * padded_value->nb[1]
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
    ggml_tensor * attention = ggml_soft_max(
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
            ggml_mul_mat(context, value_heads, attention),
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
    const sense_voice_model & model,
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
    hidden = self_attention(
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

std::string detokenize(
    const std::vector<int32_t> & token_ids,
    const std::vector<std::string> & vocabulary
) {
    std::string result;
    for (const int32_t token_id : token_ids) {
        if (token_id < 0 || token_id >= static_cast<int32_t>(vocabulary.size())) {
            continue;
        }
        const std::string & piece = vocabulary[token_id];
        if (piece.size() >= 2 && piece[0] == '<' && piece[1] == '|') {
            continue;
        }
        result += piece;
    }
    const std::string sentence_piece_space = "\xe2\x96\x81";
    size_t position;
    while ((position = result.find(sentence_piece_space)) != std::string::npos) {
        result.replace(position, sentence_piece_space.size(), " ");
    }
    return trimmed(result);
}

std::string transcribe_segment(
    const sense_voice_model & model,
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    int32_t feature_frames = 0;
    std::vector<float> features = compute_fbank(waveform, feature_frames);
    if (feature_frames == 0) {
        return {};
    }
    const int32_t query_count = static_cast<int32_t>(model.query_tokens.size());
    const int32_t total_frames = query_count + feature_frames;
    std::vector<float> input(
        static_cast<size_t>(total_frames) * feature_dimension
    );
    float * embeddings = static_cast<float *>(model.required("embed.weight")->data);
    for (int32_t index = 0; index < query_count; ++index) {
        std::memcpy(
            input.data() + static_cast<size_t>(index) * feature_dimension,
            embeddings + static_cast<size_t>(model.query_tokens[index]) * feature_dimension,
            feature_dimension * sizeof(float)
        );
    }
    std::memcpy(
        input.data() + static_cast<size_t>(query_count) * feature_dimension,
        features.data(),
        features.size() * sizeof(float)
    );
    const float scale = std::sqrt(static_cast<float>(model.config.model_dimension));
    for (float & value : input) {
        value *= scale;
    }
    add_positional_encoding(input, total_frames, feature_dimension);

    throw_if_cancelled(options);
    ggml_backend_t backend = ggml_backend_cpu_init();
    if (!backend) {
        throw std::runtime_error("无法初始化 SenseVoice CPU 后端。");
    }
    ggml_init_params graph_params = {
        static_cast<size_t>(192) * 1024 * 1024,
        nullptr,
        true
    };
    ggml_context * context = ggml_init(graph_params);
    if (!context) {
        ggml_backend_free(backend);
        throw std::runtime_error("无法创建 SenseVoice 计算图。");
    }
    ggml_tensor * graph_input = ggml_new_tensor_2d(
        context,
        GGML_TYPE_F32,
        feature_dimension,
        total_frames
    );
    ggml_set_input(graph_input);
    ggml_tensor * hidden = encoder_layer(
        context,
        model,
        "encoder.encoders0.0.",
        graph_input,
        total_frames,
        false
    );
    for (int32_t index = 0; index < model.config.encoder_blocks - 1; ++index) {
        hidden = encoder_layer(
            context,
            model,
            "encoder.encoders." + std::to_string(index) + ".",
            hidden,
            total_frames,
            true
        );
    }
    hidden = layer_norm(
        context,
        hidden,
        model.required("encoder.after_norm.weight"),
        model.required("encoder.after_norm.bias")
    );
    for (int32_t index = 0; index < model.config.temporal_blocks; ++index) {
        hidden = encoder_layer(
            context,
            model,
            "encoder.tp_encoders." + std::to_string(index) + ".",
            hidden,
            total_frames,
            true
        );
    }
    hidden = layer_norm(
        context,
        hidden,
        model.required("encoder.tp_norm.weight"),
        model.required("encoder.tp_norm.bias")
    );
    ggml_tensor * logits = linear(
        context,
        model.required("ctc.ctc_lo.weight"),
        model.required("ctc.ctc_lo.bias"),
        hidden
    );
    ggml_set_output(logits);

    ggml_cgraph * graph = ggml_new_graph_custom(context, 32768, false);
    ggml_build_forward_expand(graph, logits);
    ggml_gallocr_t allocator = ggml_gallocr_new(ggml_backend_cpu_buffer_type());
    ggml_gallocr_alloc_graph(allocator, graph);
    ggml_backend_tensor_set(graph_input, input.data(), 0, ggml_nbytes(graph_input));
    ggml_backend_cpu_set_n_threads(backend, options.threads);
    const bool computed = ggml_backend_graph_compute(backend, graph) == GGML_STATUS_SUCCESS;
    std::vector<float> values(
        static_cast<size_t>(model.config.vocabulary_size) * total_frames
    );
    if (computed) {
        ggml_backend_tensor_get(logits, values.data(), 0, ggml_nbytes(logits));
    }
    ggml_gallocr_free(allocator);
    ggml_free(context);
    ggml_backend_free(backend);
    if (!computed) {
        throw std::runtime_error("SenseVoice 推理失败。");
    }
    throw_if_cancelled(options);

    std::vector<int32_t> tokens;
    int32_t previous = -1;
    for (int32_t time = 0; time < total_frames; ++time) {
        const float * column = values.data()
            + static_cast<size_t>(time) * model.config.vocabulary_size;
        int32_t maximum_index = 0;
        float maximum_value = column[0];
        for (int32_t index = 1; index < model.config.vocabulary_size; ++index) {
            if (column[index] > maximum_value) {
                maximum_value = column[index];
                maximum_index = index;
            }
        }
        if (maximum_index != previous && maximum_index != model.config.blank_token) {
            tokens.push_back(maximum_index);
        }
        previous = maximum_index;
    }
    return detokenize(tokens, model.vocabulary);
}

} // namespace

std::string transcribe_sense_voice(
    const std::string & model_path,
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    const std::shared_ptr<sense_voice_model> model = load_model(
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

void clear_sense_voice_cache() {
    std::lock_guard<std::mutex> lock(cache_mutex);
    cached_model.reset();
    cached_path.clear();
}

} // namespace etos_local_speech
