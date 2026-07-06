// ============================================================================
// ETOSLocalLLMBridgeGeneration.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 本地文本生成实现。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"

#include <limits>
#include <sstream>

namespace etos_local_llm_bridge {

namespace {

constexpr int32_t default_prompt_batch_size = 128;

std::string context_creation_failure_message(
    const llama_context_params & ctx_params,
    const local_generation_params & generation_params
) {
    std::ostringstream stream;
    stream
        << "无法创建本地模型上下文（n_ctx=" << ctx_params.n_ctx
        << "，n_batch=" << ctx_params.n_batch
        << "，n_ubatch=" << ctx_params.n_ubatch
        << "，GPU层=" << generation_params.gpu_layers
        << "，KV offload=" << (generation_params.kv_offload ? 1 : 0)
        << "，Flash Attention=" << generation_params.flash_attention
        << "）。";
    return stream.str();
}

bool mtmd_should_use_gpu(const local_generation_params & generation_params) {
#if TARGET_OS_WATCH || TARGET_OS_SIMULATOR
    return false;
#else
    return generation_params.gpu_layers != 0;
#endif
}

int decode_token_with_position(llama_context * ctx, llama_token token, llama_pos position) {
    int32_t n_seq_id[] = { 1 };
    llama_seq_id seq_id = 0;
    llama_seq_id * seq_ids[] = { &seq_id };
    int8_t logits[] = { 1 };
    llama_batch batch = {
        1,
        &token,
        nullptr,
        &position,
        n_seq_id,
        seq_ids,
        logits,
    };
    return llama_decode(ctx, batch);
}

} // namespace

std::once_flag backend_init_once;
std::mutex model_cache_mutex;
llama_model_shared_handle cached_model;
std::string cached_model_path;
int32_t cached_model_gpu_layers = std::numeric_limits<int32_t>::min();

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

int32_t cancelled(char ** error_message) {
    if (error_message) {
        *error_message = copy_string("本地推理已取消。");
    }
    return local_llm_cancelled_status;
}

bool should_cancel(etos_local_llm_cancel_callback cancel_callback, void * user_data) {
    return cancel_callback && cancel_callback(user_data) != 0;
}

int32_t thread_count() {
    const int processors = static_cast<int>(std::thread::hardware_concurrency());
    return static_cast<int32_t>(std::max(1, std::min(8, processors > 2 ? processors - 2 : processors)));
}

llama_model_shared_handle make_model_handle(llama_model * model) {
    return llama_model_shared_handle(model, llama_model_deleter());
}

llama_model_shared_handle load_model(
    const char * model_path,
    const llama_model_params & model_params,
    bool use_model_cache
) {
    if (!use_model_cache) {
        return make_model_handle(llama_model_load_from_file(model_path, model_params));
    }

    std::lock_guard<std::mutex> lock(model_cache_mutex);
    if (cached_model
        && cached_model_path == model_path
        && cached_model_gpu_layers == model_params.n_gpu_layers) {
        return cached_model;
    }

    llama_model_shared_handle loaded_model = make_model_handle(llama_model_load_from_file(model_path, model_params));
    if (loaded_model) {
        cached_model = loaded_model;
        cached_model_path = model_path;
        cached_model_gpu_layers = model_params.n_gpu_layers;
    }
    return loaded_model;
}

void clear_model_cache() {
    std::lock_guard<std::mutex> lock(model_cache_mutex);
    cached_model.reset();
    cached_model_path.clear();
    cached_model_gpu_layers = std::numeric_limits<int32_t>::min();
}

std::string decode_failure_message(
    int status,
    const char * phase,
    int32_t generated_tokens,
    const llama_context_params & ctx_params,
    const local_generation_params & generation_params
) {
    std::ostringstream stream;
    stream
        << "本地模型解码失败（status=" << status
        << "，阶段=" << phase
        << "，已生成=" << generated_tokens
        << "，n_ctx=" << ctx_params.n_ctx
        << "，n_batch=" << ctx_params.n_batch
        << "，n_ubatch=" << ctx_params.n_ubatch
        << "，GPU层=" << generation_params.gpu_layers
        << "，KV offload=" << (generation_params.kv_offload ? 1 : 0)
        << "，Flash Attention=" << generation_params.flash_attention
        << "）。";
    return stream.str();
}

int32_t generate(
    const char * model_path,
    const char * prompt,
    const char * messages_json,
    const char * tools_json,
    const etos_local_llm_generation_config * config,
    std::string * output_text,
    std::string * output_message_json,
    etos_local_llm_token_callback token_callback,
    etos_local_llm_chat_snapshot_callback snapshot_callback,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** error_message
) {
    if (!model_path || ((!prompt || prompt[0] == '\0') && (!messages_json || messages_json[0] == '\0'))) {
        return fail("本地推理参数无效。", error_message);
    }
    if (!output_text && !output_message_json && !token_callback && !snapshot_callback) {
        return fail("本地推理输出参数无效。", error_message);
    }
    if (!config) {
        return fail("本地推理配置无效。", error_message);
    }

    local_generation_params generation_params = generation_params_from_config(*config);
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

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

    llama_model_shared_handle model = load_model(model_path, model_params, generation_params.use_model_cache);
    if (!model) {
        return fail("无法加载本地模型权重。", error_message);
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

    const llama_vocab * vocab = llama_model_get_vocab(model.get());
    const int32_t requested_context = std::max<int32_t>(1, generation_params.context_size);
    const int32_t requested_output = std::max<int32_t>(1, generation_params.max_output_tokens);

    local_chat_template_result chat_template;
    local_chat_parser_state parser_state;
    if (!prompt || prompt[0] == '\0') {
        if (should_cancel(cancel_callback, user_data)) {
            return cancelled(error_message);
        }
        chat_template = apply_chat_template_fitting_context(
            model.get(),
            vocab,
            messages_json,
            tools_json,
            generation_params.chat_template_kwargs,
            requested_context,
            error_message
        );
        if (chat_template.prompt.empty()) {
            return -1;
        }
        if (!chat_template.grammar.empty()) {
            generation_params.grammar = chat_template.grammar;
            generation_params.grammar_lazy = chat_template.grammar_lazy;
            generation_params.grammar_needs_prefill = true;
            generation_params.grammar_triggers = chat_template.grammar_triggers;
            generation_params.generation_prompt = chat_template.generation_prompt;
        }
        generation_params.additional_stops = chat_template.additional_stops;
        parser_state.enabled = chat_template.parser_enabled;
        parser_state.parser_params = chat_template.parser_params;
        prompt = chat_template.prompt.c_str();
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

    const bool uses_multimodal_prompt = !chat_template.media_ids.empty();
    std::vector<llama_token> prompt_tokens;
    size_t prompt_token_count = 0;
    llama_pos prompt_position_count = 0;
    mtmd_context_handle mtmd_ctx;
    mtmd_input_chunks_handle mtmd_chunks;
    std::vector<mtmd_bitmap_handle> media_bitmaps;
    std::vector<const mtmd_bitmap *> media_bitmap_pointers;

    if (uses_multimodal_prompt) {
        if (generation_params.mmproj_path.empty()) {
            return fail("当前本地模型包含图片输入，但尚未导入 mmproj 多模态投影器。", error_message);
        }

        mtmd_context_params mtmd_params = mtmd_context_params_default();
        mtmd_params.use_gpu = mtmd_should_use_gpu(generation_params);
        mtmd_params.print_timings = false;
        mtmd_params.n_threads = thread_count();
        mtmd_params.flash_attn_type = static_cast<llama_flash_attn_type>(generation_params.flash_attention);
        mtmd_params.warmup = false;
        mtmd_params.image_min_tokens = generation_params.image_min_tokens;
        mtmd_params.image_max_tokens = generation_params.image_max_tokens;
        mtmd_ctx.reset(mtmd_init_from_file(generation_params.mmproj_path.c_str(), model.get(), mtmd_params));
        if (!mtmd_ctx) {
            return fail("无法加载本地模型的 mmproj 多模态投影器。", error_message);
        }

        std::map<std::string, local_generation_params::media_attachment> media_by_id;
        for (const auto & attachment : generation_params.media_attachments) {
            media_by_id[attachment.id] = attachment;
        }
        media_bitmaps.reserve(chat_template.media_ids.size());
        media_bitmap_pointers.reserve(chat_template.media_ids.size());
        for (const std::string & media_id : chat_template.media_ids) {
            const auto found = media_by_id.find(media_id);
            if (found == media_by_id.end()) {
                return fail("本地多模态提示词引用了不存在的图片附件。", error_message);
            }
            mtmd_bitmap_handle bitmap(mtmd_helper_bitmap_init_from_buf(
                mtmd_ctx.get(),
                found->second.data,
                found->second.size
            ));
            if (!bitmap) {
                return fail("本地多模态图片解码失败。", error_message);
            }
            mtmd_bitmap_set_id(bitmap.get(), media_id.c_str());
            media_bitmap_pointers.push_back(bitmap.get());
            media_bitmaps.push_back(std::move(bitmap));
        }

        mtmd_chunks.reset(mtmd_input_chunks_init());
        if (!mtmd_chunks) {
            return fail("本地多模态提示词内存分配失败。", error_message);
        }
        mtmd_input_text input_text = {
            prompt,
            true,
            true,
        };
        const int32_t mtmd_status = mtmd_tokenize(
            mtmd_ctx.get(),
            mtmd_chunks.get(),
            &input_text,
            media_bitmap_pointers.data(),
            media_bitmap_pointers.size()
        );
        if (mtmd_status != 0) {
            return fail("本地多模态提示词解析失败，请确认图片数量和 mmproj 是否匹配当前模型。", error_message);
        }
        prompt_token_count = mtmd_helper_get_n_tokens(mtmd_chunks.get());
        prompt_position_count = mtmd_helper_get_n_pos(mtmd_chunks.get());
    } else {
        prompt_tokens = tokenize_prompt(vocab, prompt);
        prompt_token_count = prompt_tokens.size();
        prompt_position_count = static_cast<llama_pos>(prompt_token_count);
    }

    if (prompt_token_count == 0) {
        return fail("本地模型无法解析提示词。", error_message);
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

    if (prompt_position_count >= requested_context) {
        return fail("本地模型提示词已占满上下文窗口。请缩短聊天内容或调大上下文。", error_message);
    }
    const int32_t output_limit = std::min<int32_t>(
        requested_output,
        requested_context - static_cast<int32_t>(prompt_position_count)
    );

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = requested_context;
    const int32_t prompt_token_count_int = static_cast<int32_t>(prompt_token_count);
    const int32_t decode_batch_size = generation_params.batch_size > 0
        ? std::min<int32_t>(requested_context, generation_params.batch_size)
        : std::min<int32_t>(
            prompt_token_count_int,
            std::min<int32_t>(requested_context, default_prompt_batch_size)
        );
    ctx_params.n_batch = static_cast<uint32_t>(std::max<int32_t>(1, decode_batch_size));
    if (generation_params.ubatch_size > 0) {
        ctx_params.n_ubatch = static_cast<uint32_t>(std::min<int32_t>(
            static_cast<int32_t>(ctx_params.n_batch),
            std::max<int32_t>(1, generation_params.ubatch_size)
        ));
    }
    ctx_params.n_ubatch = std::min(ctx_params.n_ubatch, ctx_params.n_batch);
    ctx_params.n_threads = thread_count();
    ctx_params.n_threads_batch = ctx_params.n_threads;
    ctx_params.offload_kqv = generation_params.kv_offload;
    ctx_params.flash_attn_type = static_cast<llama_flash_attn_type>(generation_params.flash_attention);

    llama_context_handle ctx(llama_init_from_model(model.get(), ctx_params));
    if (!ctx) {
        return fail(context_creation_failure_message(ctx_params, generation_params), error_message);
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

    llama_sampler_handle sampler = create_sampler(model.get(), vocab, generation_params);
    if (!sampler) {
        return fail("无法创建本地模型采样器。", error_message);
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

    int32_t generated_tokens = 0;
    std::string pending_text;
    const size_t retained_stop_suffix = longest_stop_length(generation_params.additional_stops);
    const int32_t prompt_chunk_size = static_cast<int32_t>(ctx_params.n_batch);
    llama_pos n_past = 0;

    if (uses_multimodal_prompt) {
        if (should_cancel(cancel_callback, user_data)) {
            return cancelled(error_message);
        }
        llama_pos new_n_past = 0;
        const int status = mtmd_helper_eval_chunks(
            mtmd_ctx.get(),
            ctx.get(),
            mtmd_chunks.get(),
            0,
            0,
            prompt_chunk_size,
            true,
            &new_n_past
        );
        if (status != 0) {
            return fail(decode_failure_message(status, "提示词", generated_tokens, ctx_params, generation_params), error_message);
        }
        n_past = new_n_past;
    } else {
        for (size_t offset = 0; offset < prompt_tokens.size(); offset += static_cast<size_t>(prompt_chunk_size)) {
            if (should_cancel(cancel_callback, user_data)) {
                return cancelled(error_message);
            }
            const int32_t chunk_size = static_cast<int32_t>(std::min<size_t>(
                static_cast<size_t>(prompt_chunk_size),
                prompt_tokens.size() - offset
            ));
            llama_batch prompt_batch = llama_batch_get_one(prompt_tokens.data() + offset, chunk_size);
            const int status = llama_decode(ctx.get(), prompt_batch);
            if (status != 0) {
                return fail(decode_failure_message(status, "提示词", generated_tokens, ctx_params, generation_params), error_message);
            }
        }
        n_past = static_cast<llama_pos>(prompt_token_count);
    }

    bool has_pending_decode = false;
    llama_token pending_decode_token = 0;

    while (generated_tokens < output_limit) {
        if (should_cancel(cancel_callback, user_data)) {
            return cancelled(error_message);
        }
        if (has_pending_decode) {
            const int status = uses_multimodal_prompt
                ? decode_token_with_position(ctx.get(), pending_decode_token, n_past++)
                : llama_decode(ctx.get(), llama_batch_get_one(&pending_decode_token, 1));
            if (status != 0) {
                return fail(decode_failure_message(status, "生成", generated_tokens, ctx_params, generation_params), error_message);
            }
            has_pending_decode = false;
        }
        if (should_cancel(cancel_callback, user_data)) {
            return cancelled(error_message);
        }

        llama_token token = llama_sampler_sample(sampler.get(), ctx.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) {
            break;
        }
        if (should_cancel(cancel_callback, user_data)) {
            return cancelled(error_message);
        }

        std::string piece = token_to_piece(vocab, token);
        if (piece.empty()) {
            return fail("本地模型输出转换失败。", error_message);
        }

        pending_text.append(piece);
        const size_t stop_position = first_stop_position(pending_text, generation_params.additional_stops);
        if (stop_position != std::string::npos) {
            pending_text.erase(stop_position);
            if (!flush_pending_text(
                pending_text,
                0,
                true,
                output_text,
                token_callback,
                snapshot_callback,
                &parser_state,
                user_data
            )) {
                return cancelled(error_message);
            }
            break;
        }
        if (!flush_pending_text(
            pending_text,
            retained_stop_suffix > 0 ? retained_stop_suffix - 1 : 0,
            false,
            output_text,
            token_callback,
            snapshot_callback,
            &parser_state,
            user_data
        )) {
            return cancelled(error_message);
        }

        pending_decode_token = token;
        has_pending_decode = true;
        generated_tokens += 1;
    }

    if (!flush_pending_text(
        pending_text,
        0,
        true,
        output_text,
        token_callback,
        snapshot_callback,
        &parser_state,
        user_data
    )) {
        return cancelled(error_message);
    }
    if ((output_message_json || snapshot_callback) && parser_state.enabled) {
        std::string snapshot_json;
        if (!update_chat_parser_state(parser_state, false, &snapshot_json) || snapshot_json.empty()) {
            snapshot_json = fallback_chat_message_json(parser_state.generated_text);
        }
        if (output_message_json) {
            *output_message_json = snapshot_json;
        }
        if (snapshot_callback && snapshot_callback(snapshot_json.c_str(), user_data) == 0) {
            return cancelled(error_message);
        }
    } else if (output_message_json && output_text) {
        *output_message_json = fallback_chat_message_json(*output_text);
    }
    return 0;
}

} // namespace etos_local_llm_bridge
