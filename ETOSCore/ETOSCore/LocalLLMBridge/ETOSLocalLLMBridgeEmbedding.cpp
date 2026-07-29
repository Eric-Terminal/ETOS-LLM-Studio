// ============================================================================
// ETOSLocalLLMBridgeEmbedding.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 本地文本与多模态稠密嵌入实现。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"

#include <cmath>
#include <utility>

namespace etos_local_llm_bridge {
namespace {

class llama_batch_handle {
public:
    llama_batch_handle(int32_t token_count, int32_t embedding_count, int32_t sequence_count)
        : batch_(llama_batch_init(token_count, embedding_count, sequence_count)) {}

    ~llama_batch_handle() {
        llama_batch_free(batch_);
    }

    llama_batch_handle(const llama_batch_handle &) = delete;
    llama_batch_handle & operator=(const llama_batch_handle &) = delete;

    llama_batch & get() {
        return batch_;
    }

private:
    llama_batch batch_;
};

struct prepared_embedding_input {
    std::vector<llama_token> text_tokens;
    std::vector<mtmd_bitmap_handle> media_bitmaps;
    std::vector<const mtmd_bitmap *> media_bitmap_pointers;
    mtmd_input_chunks_handle multimodal_chunks;
    int32_t token_count = 0;
    llama_pos position_count = 0;

    bool is_multimodal() const {
        return static_cast<bool>(multimodal_chunks);
    }
};

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

bool mtmd_should_use_gpu(const etos_local_llm_embedding_config & config) {
#if TARGET_OS_WATCH || TARGET_OS_SIMULATOR
    return false;
#else
    return config.n_gpu_layers != 0;
#endif
}

int32_t prepare_multimodal_input(
    const char * text,
    int32_t input_index,
    const std::vector<int32_t> & media_indices,
    const etos_local_llm_embedding_config & config,
    mtmd_context * mtmd_ctx,
    prepared_embedding_input * prepared,
    char ** error_message
) {
    prepared->media_bitmaps.reserve(media_indices.size());
    prepared->media_bitmap_pointers.reserve(media_indices.size());
    for (const int32_t media_index : media_indices) {
        const unsigned char * data = config.media_data[media_index];
        const int64_t byte_count = config.media_data_sizes[media_index];
        const char * media_id = config.media_ids[media_index];
        if (!data || byte_count <= 0 || !media_id || media_id[0] == '\0') {
            return fail("本地多模态嵌入附件参数无效。", error_message);
        }

        mtmd_bitmap_handle bitmap(mtmd_helper_bitmap_init_from_buf(
            mtmd_ctx,
            data,
            static_cast<size_t>(byte_count)
        ));
        if (!bitmap) {
            return fail("本地多模态嵌入无法解码图片或音频附件。", error_message);
        }
        mtmd_bitmap_set_id(bitmap.get(), media_id);
        prepared->media_bitmap_pointers.push_back(bitmap.get());
        prepared->media_bitmaps.push_back(std::move(bitmap));
    }

    prepared->multimodal_chunks.reset(mtmd_input_chunks_init());
    if (!prepared->multimodal_chunks) {
        return fail("无法创建本地多模态嵌入输入。", error_message);
    }
    mtmd_input_text input_text = {
        text,
        true,
        true,
    };
    const int32_t tokenize_status = mtmd_tokenize(
        mtmd_ctx,
        prepared->multimodal_chunks.get(),
        &input_text,
        prepared->media_bitmap_pointers.data(),
        prepared->media_bitmap_pointers.size()
    );
    if (tokenize_status != 0) {
        return fail(
            tokenize_status == 1
                ? "本地多模态嵌入的媒体标记与附件数量不一致。"
                : "本地多模态嵌入预处理失败。",
            error_message
        );
    }

    prepared->token_count = static_cast<int32_t>(
        mtmd_helper_get_n_tokens(prepared->multimodal_chunks.get())
    );
    prepared->position_count = mtmd_helper_get_n_pos(prepared->multimodal_chunks.get());
    if (prepared->token_count <= 0 || prepared->position_count <= 0) {
        return fail(
            "本地多模态嵌入模型无法解析第 " + std::to_string(input_index + 1) + " 个输入。",
            error_message
        );
    }
    return 0;
}

} // namespace

int32_t embed(
    const char * model_path,
    const char * const * texts,
    int32_t input_count,
    const etos_local_llm_embedding_config * config,
    std::vector<float> * output_embeddings,
    int32_t * embedding_dimension,
    char ** error_message
) {
    if (!model_path || !texts || input_count <= 0 || !config || !output_embeddings || !embedding_dimension) {
        return fail("本地嵌入参数无效。", error_message);
    }
    if (config->media_count < 0) {
        return fail("本地多模态嵌入附件数量无效。", error_message);
    }
    const bool has_media = config->media_count > 0;
    if (has_media && (
        !config->media_data
        || !config->media_data_sizes
        || !config->media_ids
        || !config->media_input_indices
    )) {
        return fail("本地多模态嵌入附件参数不完整。", error_message);
    }
    if (has_media && (!config->mmproj_path || config->mmproj_path[0] == '\0')) {
        return fail("当前本地嵌入输入包含媒体，但尚未导入 mmproj 多模态投影器。", error_message);
    }

    std::call_once(backend_init_once, [] {
        llama_backend_init();
        ggml_backend_load_all();
    });

    llama_model_params model_params = llama_model_default_params();
#if TARGET_OS_WATCH || TARGET_OS_SIMULATOR
    model_params.n_gpu_layers = 0;
#else
    model_params.n_gpu_layers = config->n_gpu_layers < 0 ? 999 : config->n_gpu_layers;
#endif

    llama_model_handle model(llama_model_load_from_file(model_path, model_params));
    if (!model) {
        return fail("无法加载本地嵌入模型权重。", error_message);
    }
    if (llama_model_has_encoder(model.get()) && llama_model_has_decoder(model.get())) {
        return fail("当前 llama.cpp 不支持 encoder-decoder 模型生成嵌入。", error_message);
    }
    const bool uses_encoder = llama_model_has_encoder(model.get());
    if (has_media && uses_encoder) {
        return fail("当前 llama.cpp 多模态嵌入仅支持 decoder 架构模型。", error_message);
    }

    mtmd_context_handle mtmd_ctx;
    if (has_media) {
        mtmd_context_params mtmd_params = mtmd_context_params_default();
        mtmd_params.use_gpu = mtmd_should_use_gpu(*config);
        mtmd_params.print_timings = false;
        mtmd_params.n_threads = thread_count();
        mtmd_params.flash_attn_type = static_cast<llama_flash_attn_type>(config->flash_attention);
        mtmd_params.warmup = false;
        mtmd_params.image_min_tokens = config->image_min_tokens;
        mtmd_params.image_max_tokens = config->image_max_tokens;
        mtmd_ctx.reset(mtmd_init_from_file(config->mmproj_path, model.get(), mtmd_params));
        if (!mtmd_ctx) {
            return fail("无法加载本地嵌入模型的 mmproj 多模态投影器。", error_message);
        }
    }

    std::vector<std::vector<int32_t>> media_indices_by_input(static_cast<size_t>(input_count));
    for (int32_t media_index = 0; media_index < config->media_count; ++media_index) {
        const int32_t input_index = config->media_input_indices[media_index];
        if (input_index < 0 || input_index >= input_count) {
            return fail("本地多模态嵌入附件引用了不存在的输入。", error_message);
        }
        media_indices_by_input[static_cast<size_t>(input_index)].push_back(media_index);
    }

    const llama_vocab * vocab = llama_model_get_vocab(model.get());
    std::vector<prepared_embedding_input> prepared_inputs(static_cast<size_t>(input_count));
    int32_t max_token_count = 1;
    llama_pos max_position_count = 1;
    for (int32_t input_index = 0; input_index < input_count; ++input_index) {
        const char * text = texts[input_index];
        if (!text || text[0] == '\0') {
            return fail("本地嵌入输入不能为空。", error_message);
        }

        auto & prepared = prepared_inputs[static_cast<size_t>(input_index)];
        const auto & media_indices = media_indices_by_input[static_cast<size_t>(input_index)];
        if (!media_indices.empty()) {
            const int32_t status = prepare_multimodal_input(
                text,
                input_index,
                media_indices,
                *config,
                mtmd_ctx.get(),
                &prepared,
                error_message
            );
            if (status != 0) {
                return status;
            }
        } else {
            prepared.text_tokens = tokenize(vocab, text);
            if (prepared.text_tokens.empty()) {
                return fail("本地嵌入模型无法解析输入文本。", error_message);
            }
            prepared.token_count = static_cast<int32_t>(prepared.text_tokens.size());
            prepared.position_count = prepared.token_count;
        }

        max_token_count = std::max(max_token_count, prepared.token_count);
        max_position_count = std::max(max_position_count, prepared.position_count);
    }

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.embeddings = true;
    ctx_params.n_ctx = static_cast<uint32_t>(std::max<llama_pos>(
        std::max(1, config->context_size),
        max_position_count
    ));
    ctx_params.n_batch = std::max<uint32_t>(1, std::min<uint32_t>(
        ctx_params.n_ctx,
        static_cast<uint32_t>(std::max(1, max_token_count))
    ));
    ctx_params.n_ubatch = ctx_params.n_batch;
    ctx_params.n_threads = thread_count();
    ctx_params.n_threads_batch = ctx_params.n_threads;
    ctx_params.flash_attn_type = static_cast<llama_flash_attn_type>(config->flash_attention);

    llama_context_handle ctx(llama_init_from_model(model.get(), ctx_params));
    if (!ctx) {
        return fail("无法创建本地嵌入上下文。", error_message);
    }
    llama_set_embeddings(ctx.get(), true);

    const int32_t dimension = llama_model_n_embd_out(model.get());
    if (dimension <= 0) {
        return fail("本地嵌入模型输出维度无效。", error_message);
    }

    output_embeddings->assign(static_cast<size_t>(input_count) * static_cast<size_t>(dimension), 0.0f);
    for (int32_t input_index = 0; input_index < input_count; ++input_index) {
        auto & prepared = prepared_inputs[static_cast<size_t>(input_index)];
        llama_memory_clear(llama_get_memory(ctx.get()), true);

        if (prepared.is_multimodal()) {
            llama_pos new_position = 0;
            const int32_t status = mtmd_helper_eval_chunks(
                mtmd_ctx.get(),
                ctx.get(),
                prepared.multimodal_chunks.get(),
                0,
                0,
                static_cast<int32_t>(ctx_params.n_batch),
                true,
                &new_position
            );
            if (status != 0) {
                return fail("本地多模态嵌入模型解码失败。", error_message);
            }
        } else {
            llama_batch_handle batch(prepared.token_count, 0, 1);
            for (int32_t token_index = 0; token_index < prepared.token_count; ++token_index) {
                batch_add(
                    batch.get(),
                    prepared.text_tokens[static_cast<size_t>(token_index)],
                    token_index,
                    0,
                    true
                );
            }
            const int32_t status = uses_encoder
                ? llama_encode(ctx.get(), batch.get())
                : llama_decode(ctx.get(), batch.get());
            if (status < 0) {
                return fail("本地嵌入模型解码失败。", error_message);
            }
        }

        float * destination = output_embeddings->data()
            + static_cast<size_t>(input_index) * static_cast<size_t>(dimension);
        const float * embedding = llama_get_embeddings_seq(ctx.get(), 0);
        if (embedding) {
            normalize_embedding(embedding, destination, dimension);
            continue;
        }
        if (prepared.is_multimodal()) {
            return fail("当前多模态 GGUF 未提供可用于检索的池化嵌入向量。", error_message);
        }

        std::vector<float> mean(static_cast<size_t>(dimension), 0.0f);
        int32_t pooled_count = 0;
        for (int32_t token_index = 0; token_index < prepared.token_count; ++token_index) {
            const float * token_embedding = llama_get_embeddings_ith(ctx.get(), token_index);
            if (!token_embedding) {
                continue;
            }
            for (int32_t dimension_index = 0; dimension_index < dimension; ++dimension_index) {
                mean[static_cast<size_t>(dimension_index)] += token_embedding[dimension_index];
            }
            pooled_count += 1;
        }
        if (pooled_count == 0) {
            return fail("无法读取本地嵌入向量。", error_message);
        }
        for (float & value : mean) {
            value /= static_cast<float>(pooled_count);
        }
        normalize_embedding(mean.data(), destination, dimension);
    }

    *embedding_dimension = dimension;
    return 0;
}

} // namespace etos_local_llm_bridge
