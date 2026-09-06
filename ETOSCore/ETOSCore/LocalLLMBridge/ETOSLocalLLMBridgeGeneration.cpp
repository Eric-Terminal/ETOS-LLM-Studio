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

struct text_kv_cache_state {
    std::string cache_key;
    std::string model_path;
    std::string lora_path;
    float lora_scale = 1.0f;
    int32_t gpu_layers = std::numeric_limits<int32_t>::min();
    uint32_t context_size = 0;
    uint32_t batch_size = 0;
    uint32_t ubatch_size = 0;
    bool kv_offload = true;
    llama_flash_attn_type flash_attention = LLAMA_FLASH_ATTN_TYPE_AUTO;
    llama_model_shared_handle model;
    llama_adapter_lora_handle lora_adapter;
    llama_context_handle context;
    std::vector<llama_token> decoded_tokens;
};

// llama_context 不能并发访问；这里只驻留最近一个普通文本对话的上下文。
std::mutex text_kv_cache_mutex;
text_kv_cache_state text_kv_cache;

void reset_text_kv_cache() {
    text_kv_cache.context.reset();
    text_kv_cache.lora_adapter.reset();
    text_kv_cache.model.reset();
    text_kv_cache.decoded_tokens.clear();
    text_kv_cache.cache_key.clear();
    text_kv_cache.model_path.clear();
    text_kv_cache.lora_path.clear();
    text_kv_cache.lora_scale = 1.0f;
    text_kv_cache.gpu_layers = std::numeric_limits<int32_t>::min();
    text_kv_cache.context_size = 0;
    text_kv_cache.batch_size = 0;
    text_kv_cache.ubatch_size = 0;
}

bool text_kv_cache_matches(
    const std::string & cache_key,
    const std::string & model_path,
    const std::string & lora_path,
    float lora_scale,
    int32_t gpu_layers,
    const llama_context_params & context_params
) {
    return text_kv_cache.context
        && text_kv_cache.cache_key == cache_key
        && text_kv_cache.model_path == model_path
        && text_kv_cache.lora_path == lora_path
        && text_kv_cache.lora_scale == lora_scale
        && (lora_path.empty() || text_kv_cache.lora_adapter)
        && text_kv_cache.gpu_layers == gpu_layers
        && text_kv_cache.context_size == context_params.n_ctx
        && text_kv_cache.batch_size == context_params.n_batch
        && text_kv_cache.ubatch_size == context_params.n_ubatch
        && text_kv_cache.kv_offload == context_params.offload_kqv
        && text_kv_cache.flash_attention == context_params.flash_attn_type;
}

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
    bool use_model_cache,
    std::string * diagnostic_log
) {
    if (!use_model_cache) {
        native_log_capture capture;
        llama_model_shared_handle loaded_model = make_model_handle(llama_model_load_from_file(model_path, model_params));
        if (!loaded_model && diagnostic_log) {
            *diagnostic_log = capture.text();
        }
        return loaded_model;
    }

    std::lock_guard<std::mutex> lock(model_cache_mutex);
    if (cached_model
        && cached_model_path == model_path
        && cached_model_gpu_layers == model_params.n_gpu_layers) {
        return cached_model;
    }

    native_log_capture capture;
    llama_model_shared_handle loaded_model = make_model_handle(llama_model_load_from_file(model_path, model_params));
    if (loaded_model) {
        cached_model = loaded_model;
        cached_model_path = model_path;
        cached_model_gpu_layers = model_params.n_gpu_layers;
    } else if (diagnostic_log) {
        *diagnostic_log = capture.text();
    }
    return loaded_model;
}

void clear_model_cache() {
    std::lock_guard<std::mutex> lock(model_cache_mutex);
    cached_model.reset();
    cached_model_path.clear();
    cached_model_gpu_layers = std::numeric_limits<int32_t>::min();
}

void clear_kv_cache(const char * expected_cache_key) {
    std::lock_guard<std::mutex> lock(text_kv_cache_mutex);
    if (expected_cache_key
        && text_kv_cache.cache_key != expected_cache_key) {
        return;
    }
    reset_text_kv_cache();
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

    initialize_backend();

    llama_model_params model_params = llama_model_default_params();
#if TARGET_OS_WATCH || TARGET_OS_SIMULATOR
    model_params.n_gpu_layers = 0;
#else
    model_params.n_gpu_layers = generation_params.gpu_layers < 0 ? 999 : generation_params.gpu_layers;
#endif

    std::string model_load_log;
    llama_model_shared_handle model = load_model(
        model_path,
        model_params,
        generation_params.use_model_cache,
        &model_load_log
    );
    if (!model) {
        return fail(
            diagnostic_message("无法加载本地模型权重。", model_load_log),
            error_message
        );
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

    native_log_capture runtime_log_capture;

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
            return fail(diagnostic_message(
                "无法加载本地模型的 mmproj 多模态投影器。",
                runtime_log_capture.text()
            ), error_message);
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
    const bool wants_text_kv_cache = generation_params.reuse_kv_cache
        && !generation_params.kv_cache_key.empty();
    const int32_t automatic_batch_size = wants_text_kv_cache
        ? std::min<int32_t>(requested_context, default_prompt_batch_size)
        : std::min<int32_t>(
            prompt_token_count_int,
            std::min<int32_t>(requested_context, default_prompt_batch_size)
        );
    const int32_t decode_batch_size = generation_params.batch_size > 0
        ? std::min<int32_t>(requested_context, generation_params.batch_size)
        : automatic_batch_size;
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

    const bool can_reuse_text_kv_cache = wants_text_kv_cache && !uses_multimodal_prompt;
    std::unique_lock<std::mutex> text_kv_cache_lock;
    llama_adapter_lora_handle lora_adapter;
    llama_context_handle ctx;
    std::vector<llama_token> decoded_text_tokens;
    size_t reusable_prompt_tokens = 0;

    if (wants_text_kv_cache) {
        text_kv_cache_lock = std::unique_lock<std::mutex>(text_kv_cache_mutex);
        if (can_reuse_text_kv_cache
            && text_kv_cache_matches(
                generation_params.kv_cache_key,
                model_path,
                generation_params.lora_path,
                generation_params.lora_scale,
                model_params.n_gpu_layers,
                ctx_params
            )) {
            ctx = std::move(text_kv_cache.context);
            model = text_kv_cache.model;
            lora_adapter = std::move(text_kv_cache.lora_adapter);
            decoded_text_tokens = std::move(text_kv_cache.decoded_tokens);
            vocab = llama_model_get_vocab(model.get());
        }
        reset_text_kv_cache();

        if (!can_reuse_text_kv_cache) {
            text_kv_cache_lock.unlock();
        } else if (ctx) {
            const size_t comparable_count = std::min(
                decoded_text_tokens.size(),
                prompt_tokens.size()
            );
            while (reusable_prompt_tokens < comparable_count
                && decoded_text_tokens[reusable_prompt_tokens]
                    == prompt_tokens[reusable_prompt_tokens]) {
                ++reusable_prompt_tokens;
            }

            // 至少重放一个 token，确保当前请求的采样 logits 与裁剪后的 KV 对齐。
            if (reusable_prompt_tokens == prompt_tokens.size()
                && reusable_prompt_tokens > 0) {
                --reusable_prompt_tokens;
            }
            if (decoded_text_tokens.size() > reusable_prompt_tokens) {
                if (!llama_memory_seq_rm(
                        llama_get_memory(ctx.get()),
                        -1,
                        static_cast<llama_pos>(reusable_prompt_tokens),
                        -1
                    )) {
                    llama_memory_clear(llama_get_memory(ctx.get()), true);
                    reusable_prompt_tokens = 0;
                }
                decoded_text_tokens.resize(reusable_prompt_tokens);
            }
        }
    }

    if (!ctx && !generation_params.lora_path.empty()) {
        lora_adapter.reset(llama_adapter_lora_init(model.get(), generation_params.lora_path.c_str()));
        if (!lora_adapter) {
            return fail(diagnostic_message(
                "无法加载或匹配 LoRA Adapter。",
                runtime_log_capture.text()
            ), error_message);
        }
    }
    if (!ctx) {
        ctx.reset(llama_init_from_model(model.get(), ctx_params));
    }
    if (!ctx) {
        return fail(diagnostic_message(
            context_creation_failure_message(ctx_params, generation_params),
            runtime_log_capture.text()
        ), error_message);
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }
    if (lora_adapter) {
        llama_adapter_lora * adapters[] = {lora_adapter.get()};
        float scales[] = {generation_params.lora_scale};
        if (llama_set_adapters_lora(ctx.get(), adapters, 1, scales) != 0) {
            return fail(diagnostic_message(
                "无法将 LoRA Adapter 应用到本地模型上下文。",
                runtime_log_capture.text()
            ), error_message);
        }
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
    llama_pos n_past = static_cast<llama_pos>(reusable_prompt_tokens);

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
            return fail(diagnostic_message(
                decode_failure_message(status, "提示词", generated_tokens, ctx_params, generation_params),
                runtime_log_capture.text()
            ), error_message);
        }
        n_past = new_n_past;
    } else {
        for (size_t offset = reusable_prompt_tokens;
             offset < prompt_tokens.size();
             offset += static_cast<size_t>(prompt_chunk_size)) {
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
                return fail(diagnostic_message(
                    decode_failure_message(status, "提示词", generated_tokens, ctx_params, generation_params),
                    runtime_log_capture.text()
                ), error_message);
            }
            decoded_text_tokens.insert(
                decoded_text_tokens.end(),
                prompt_tokens.begin() + static_cast<std::ptrdiff_t>(offset),
                prompt_tokens.begin() + static_cast<std::ptrdiff_t>(offset + chunk_size)
            );
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
                return fail(diagnostic_message(
                    decode_failure_message(status, "生成", generated_tokens, ctx_params, generation_params),
                    runtime_log_capture.text()
                ), error_message);
            }
            if (!uses_multimodal_prompt) {
                decoded_text_tokens.push_back(pending_decode_token);
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
    if (can_reuse_text_kv_cache) {
        text_kv_cache.cache_key = generation_params.kv_cache_key;
        text_kv_cache.model_path = model_path;
        text_kv_cache.lora_path = generation_params.lora_path;
        text_kv_cache.lora_scale = generation_params.lora_scale;
        text_kv_cache.gpu_layers = model_params.n_gpu_layers;
        text_kv_cache.context_size = ctx_params.n_ctx;
        text_kv_cache.batch_size = ctx_params.n_batch;
        text_kv_cache.ubatch_size = ctx_params.n_ubatch;
        text_kv_cache.kv_offload = ctx_params.offload_kqv;
        text_kv_cache.flash_attention = ctx_params.flash_attn_type;
        text_kv_cache.model = model;
        text_kv_cache.lora_adapter = std::move(lora_adapter);
        text_kv_cache.context = std::move(ctx);
        text_kv_cache.decoded_tokens = std::move(decoded_text_tokens);
    }
    return 0;
}

} // namespace etos_local_llm_bridge
