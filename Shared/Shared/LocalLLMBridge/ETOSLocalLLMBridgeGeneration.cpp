// ============================================================================
// ETOSLocalLLMBridgeGeneration.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 本地文本生成实现。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"

#include "nlohmann/json.hpp"

#include <cctype>
#include <cmath>
#include <limits>
#include <sstream>
#include <utility>

using json = nlohmann::ordered_json;

namespace etos_local_llm_bridge {

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

struct local_chat_template_result {
    std::string prompt;
    std::string grammar;
    bool grammar_lazy = false;
    std::vector<common_grammar_trigger> grammar_triggers;
    std::string generation_prompt;
    std::vector<std::string> additional_stops;
    common_chat_parser_params parser_params;
    bool parser_enabled = false;
};

local_generation_params generation_params_from_config(const etos_local_llm_generation_config & config) {
    local_generation_params params;
    params.context_size = std::max<int32_t>(1, config.context_size);
    params.max_output_tokens = std::max<int32_t>(1, config.max_output_tokens);
    params.gpu_layers = config.gpu_layers;
    params.batch_size = std::max<int32_t>(0, config.batch_size);
    params.ubatch_size = std::max<int32_t>(0, config.ubatch_size);
    params.kv_offload = config.kv_offload != 0;
    switch (config.flash_attention) {
    case LLAMA_FLASH_ATTN_TYPE_DISABLED:
    case LLAMA_FLASH_ATTN_TYPE_ENABLED:
    case LLAMA_FLASH_ATTN_TYPE_AUTO:
        params.flash_attention = config.flash_attention;
        break;
    default:
        params.flash_attention = LLAMA_FLASH_ATTN_TYPE_AUTO;
        break;
    }
    params.use_model_cache = config.use_model_cache != 0;
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

std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool add_special) {
    const int32_t token_count = -llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()), nullptr, 0, add_special, true);
    if (token_count <= 0) {
        return {};
    }
    std::vector<llama_token> tokens(static_cast<size_t>(token_count));
    const int32_t written = llama_tokenize(
        vocab,
        text.c_str(),
        static_cast<int32_t>(text.size()),
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        add_special,
        true
    );
    if (written < 0) {
        return {};
    }
    tokens.resize(static_cast<size_t>(written));
    return tokens;
}

std::vector<llama_token> tokenize_prompt(const llama_vocab * vocab, const std::string & prompt) {
    return tokenize(vocab, prompt, true);
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

llama_sampler_handle create_sampler(
    const llama_model * model,
    const llama_vocab * vocab,
    const local_generation_params & params
) {
    llama_sampler_handle sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()));
    if (!sampler) {
        return {};
    }

    if (params.ignore_eos) {
        llama_logit_bias eos_bias = {
            llama_vocab_eos(vocab),
            -INFINITY
        };
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), 1, &eos_bias));
    }

    const size_t min_keep = params.min_keep <= 0 ? 0 : static_cast<size_t>(params.min_keep);
    bool uses_terminal_sampler = false;
    if (params.mirostat == 0) {
        for (const int32_t sampler_kind : params.sampler_kinds) {
            switch (sampler_kind) {
            case ETOS_LOCAL_LLM_SAMPLER_PENALTIES:
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_penalties(
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
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_dry(
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
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_n_sigma(params.top_n_sigma));
                break;
            case ETOS_LOCAL_LLM_SAMPLER_TOP_K:
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(params.top_k));
                break;
            case ETOS_LOCAL_LLM_SAMPLER_TYPICAL:
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_typical(params.typical_p, min_keep));
                break;
            case ETOS_LOCAL_LLM_SAMPLER_TOP_P:
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(params.top_p, min_keep));
                break;
            case ETOS_LOCAL_LLM_SAMPLER_MIN_P:
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_min_p(params.min_p, min_keep));
                break;
            case ETOS_LOCAL_LLM_SAMPLER_XTC:
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_xtc(params.xtc_probability, params.xtc_threshold, min_keep, params.seed));
                break;
            case ETOS_LOCAL_LLM_SAMPLER_TEMPERATURE:
                llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp_ext(params.temperature, params.dynatemp_range, params.dynatemp_exponent));
                break;
            case ETOS_LOCAL_LLM_SAMPLER_ADAPTIVE:
                uses_terminal_sampler = true;
                break;
            default:
                break;
            }
        }
    } else {
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(params.temperature));
    }

    if (!params.grammar.empty()) {
        std::vector<std::string> trigger_patterns;
        std::vector<llama_token> trigger_tokens;
        for (const auto & trigger : params.grammar_triggers) {
            switch (trigger.type) {
            case COMMON_GRAMMAR_TRIGGER_TYPE_WORD:
                trigger_patterns.push_back(regex_escape(trigger.value));
                break;
            case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN:
                trigger_patterns.push_back(trigger.value);
                break;
            case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN_FULL: {
                std::string anchored = "^$";
                if (!trigger.value.empty()) {
                    anchored = (trigger.value.front() != '^' ? "^" : "")
                        + trigger.value
                        + (trigger.value.back() != '$' ? "$" : "");
                }
                trigger_patterns.push_back(anchored);
                break;
            }
            case COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN:
                trigger_tokens.push_back(trigger.token);
                break;
            }
        }

        std::vector<const char *> trigger_patterns_c;
        trigger_patterns_c.reserve(trigger_patterns.size());
        for (const auto & pattern : trigger_patterns) {
            trigger_patterns_c.push_back(pattern.c_str());
        }

        llama_sampler_handle grammar_sampler(params.grammar_lazy
            ? llama_sampler_init_grammar_lazy_patterns(
                vocab,
                params.grammar.c_str(),
                "root",
                trigger_patterns_c.data(),
                trigger_patterns_c.size(),
                trigger_tokens.data(),
                trigger_tokens.size()
            )
            : llama_sampler_init_grammar(vocab, params.grammar.c_str(), "root"));
        if (!grammar_sampler) {
            return {};
        }
        if (!params.grammar_lazy && params.grammar_needs_prefill && !params.generation_prompt.empty()) {
            const auto prefill_tokens = tokenize(vocab, params.generation_prompt, false);
            for (size_t index = 0; index < prefill_tokens.size(); ++index) {
                const std::string piece = token_to_piece(vocab, prefill_tokens[index]);
                if (index == 0
                    && !piece.empty()
                    && !params.generation_prompt.empty()
                    && std::isspace(static_cast<unsigned char>(piece[0]))
                    && !std::isspace(static_cast<unsigned char>(params.generation_prompt[0]))) {
                    continue;
                }
                llama_sampler_accept(grammar_sampler.get(), prefill_tokens[index]);
            }
        }
        llama_sampler_chain_add(sampler.get(), grammar_sampler.release());
    }
    if (params.mirostat == 1) {
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_mirostat(llama_vocab_n_tokens(vocab), params.seed, params.mirostat_tau, params.mirostat_eta, 100));
    } else if (params.mirostat == 2) {
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_mirostat_v2(params.seed, params.mirostat_tau, params.mirostat_eta));
    } else if (uses_terminal_sampler) {
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_adaptive_p(params.adaptive_target, params.adaptive_decay, params.seed));
    } else if (params.temperature <= 0.0f) {
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(params.seed));
    }
    return sampler;
}

size_t longest_stop_length(const std::vector<std::string> & stops) {
    size_t length = 0;
    for (const std::string & stop : stops) {
        length = std::max(length, stop.size());
    }
    return length;
}

size_t first_stop_position(const std::string & text, const std::vector<std::string> & stops) {
    size_t position = std::string::npos;
    for (const std::string & stop : stops) {
        if (stop.empty()) {
            continue;
        }
        const size_t found = text.find(stop);
        if (found != std::string::npos) {
            position = std::min(position, found);
        }
    }
    return position;
}

bool is_utf8_continuation_byte(unsigned char byte) {
    return (byte & 0xC0) == 0x80;
}

bool valid_utf8_codepoint_at(const std::string & text, size_t index, size_t limit, size_t & length) {
    const unsigned char first = static_cast<unsigned char>(text[index]);
    if (first <= 0x7F) {
        length = 1;
        return true;
    }

    if (first >= 0xC2 && first <= 0xDF) {
        length = 2;
        return index + length <= limit && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 1]));
    }

    if (first == 0xE0) {
        length = 3;
        if (index + length > limit) {
            return false;
        }
        const unsigned char second = static_cast<unsigned char>(text[index + 1]);
        return second >= 0xA0 && second <= 0xBF
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 2]));
    }

    if ((first >= 0xE1 && first <= 0xEC) || (first >= 0xEE && first <= 0xEF)) {
        length = 3;
        return index + length <= limit
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 1]))
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 2]));
    }

    if (first == 0xED) {
        length = 3;
        if (index + length > limit) {
            return false;
        }
        const unsigned char second = static_cast<unsigned char>(text[index + 1]);
        return second >= 0x80 && second <= 0x9F
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 2]));
    }

    if (first == 0xF0) {
        length = 4;
        if (index + length > limit) {
            return false;
        }
        const unsigned char second = static_cast<unsigned char>(text[index + 1]);
        return second >= 0x90 && second <= 0xBF
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 2]))
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 3]));
    }

    if (first >= 0xF1 && first <= 0xF3) {
        length = 4;
        return index + length <= limit
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 1]))
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 2]))
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 3]));
    }

    if (first == 0xF4) {
        length = 4;
        if (index + length > limit) {
            return false;
        }
        const unsigned char second = static_cast<unsigned char>(text[index + 1]);
        return second >= 0x80 && second <= 0x8F
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 2]))
            && is_utf8_continuation_byte(static_cast<unsigned char>(text[index + 3]));
    }

    length = 0;
    return false;
}

size_t valid_utf8_prefix_length(const std::string & text, size_t limit) {
    limit = std::min(limit, text.size());

    size_t index = 0;
    while (index < limit) {
        size_t codepoint_length = 0;
        if (!valid_utf8_codepoint_at(text, index, limit, codepoint_length)) {
            break;
        }
        index += codepoint_length;
    }
    return index;
}

std::string next_local_tool_call_id(local_chat_parser_state & state) {
    return "local_tool_" + std::to_string(state.next_tool_call_index++);
}

std::string fallback_chat_message_json(const std::string & content) {
    json message = {
        { "role", "assistant" },
        { "content", content },
    };
    return message.dump();
}

bool update_chat_parser_state(
    local_chat_parser_state & state,
    bool is_partial,
    std::string * snapshot_json
) {
    if (!state.enabled) {
        return false;
    }

    try {
        common_chat_msg parsed = common_chat_parse(state.generated_text, is_partial, state.parser_params);
        if (parsed.empty()) {
            return false;
        }
        parsed.set_tool_call_ids(state.tool_call_ids, [&state] {
            return next_local_tool_call_id(state);
        });
        state.message = std::move(parsed);
        if (snapshot_json) {
            *snapshot_json = state.message.to_json_oaicompat(true).dump();
        }
        return true;
    } catch (const std::exception &) {
        if (!is_partial && snapshot_json) {
            *snapshot_json = fallback_chat_message_json(state.generated_text);
            return true;
        }
        return false;
    }
}

bool emit_text_chunk(
    const std::string & chunk,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
    etos_local_llm_chat_snapshot_callback snapshot_callback,
    local_chat_parser_state * parser_state,
    void * user_data
) {
    if (chunk.empty()) {
        return true;
    }
    if (output_text) {
        output_text->append(chunk);
    }
    if (parser_state && parser_state->enabled) {
        parser_state->generated_text.append(chunk);
    }
    if (token_callback && token_callback(chunk.c_str(), user_data) == 0) {
        return false;
    }
    if (snapshot_callback && parser_state && parser_state->enabled) {
        std::string snapshot_json;
        if (update_chat_parser_state(*parser_state, true, &snapshot_json) && !snapshot_json.empty()) {
            return snapshot_callback(snapshot_json.c_str(), user_data) != 0;
        }
    }
    return true;
}

bool flush_pending_text(
    std::string & pending_text,
    size_t retained_suffix_length,
    bool final_flush,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
    etos_local_llm_chat_snapshot_callback snapshot_callback,
    local_chat_parser_state * parser_state,
    void * user_data
) {
    if (pending_text.empty()) {
        return true;
    }
    const size_t retained_length = final_flush ? 0 : std::min(retained_suffix_length, pending_text.size());
    if (pending_text.size() <= retained_length) {
        return true;
    }

    const size_t candidate_length = pending_text.size() - retained_length;
    const size_t chunk_length = valid_utf8_prefix_length(pending_text, candidate_length);
    if (chunk_length == 0) {
        if (final_flush) {
            if (output_text) {
                output_text->append(pending_text);
            }
            if (parser_state && parser_state->enabled) {
                parser_state->generated_text.append(pending_text);
            }
            pending_text.clear();
        }
        return true;
    }

    std::string chunk = pending_text.substr(0, chunk_length);
    pending_text.erase(0, chunk_length);
    const bool should_continue = emit_text_chunk(
        chunk,
        output_text,
        token_callback,
        snapshot_callback,
        parser_state,
        user_data
    );
    if (final_flush && !pending_text.empty()) {
        if (output_text) {
            output_text->append(pending_text);
        }
        if (parser_state && parser_state->enabled) {
            parser_state->generated_text.append(pending_text);
        }
        pending_text.clear();
    }
    return should_continue;
}

local_chat_template_result apply_chat_template(
    const llama_model * model,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    char ** error_message
) {
    if (!messages || message_count <= 0) {
        fail("本地对话消息为空。", error_message);
        return {};
    }

    json chat_messages = json::array();
    for (int32_t index = 0; index < message_count; ++index) {
        const char * role = messages[index].role;
        const char * content = messages[index].content;
        if (!role || role[0] == '\0') {
            continue;
        }

        json message = {
            { "role", role },
        };
        if (content) {
            message["content"] = content;
        }
        if (messages[index].reasoning_content && messages[index].reasoning_content[0] != '\0') {
            message["reasoning_content"] = messages[index].reasoning_content;
        }
        if (messages[index].name && messages[index].name[0] != '\0') {
            message["name"] = messages[index].name;
        }
        if (messages[index].tool_call_id && messages[index].tool_call_id[0] != '\0') {
            message["tool_call_id"] = messages[index].tool_call_id;
        }
        if (messages[index].tool_calls_json && messages[index].tool_calls_json[0] != '\0') {
            try {
                message["tool_calls"] = json::parse(messages[index].tool_calls_json);
            } catch (const std::exception & e) {
                fail(std::string("本地工具调用历史 JSON 无效：") + e.what(), error_message);
                return {};
            }
        }
        chat_messages.push_back(std::move(message));
    }

    if (chat_messages.empty()) {
        fail("本地对话消息为空。", error_message);
        return {};
    }

    json tool_definitions = json::array();
    for (int32_t index = 0; tools && index < tool_count; ++index) {
        const char * name = tools[index].name;
        if (!name || name[0] == '\0') {
            continue;
        }

        json parameters = json::object();
        if (tools[index].parameters_json && tools[index].parameters_json[0] != '\0') {
            try {
                parameters = json::parse(tools[index].parameters_json);
            } catch (const std::exception & e) {
                fail(std::string("本地工具参数 JSON Schema 无效：") + e.what(), error_message);
                return {};
            }
        }
        tool_definitions.push_back({
            { "type", "function" },
            { "function", {
                { "name", name },
                { "description", tools[index].description ? tools[index].description : "" },
                { "parameters", parameters },
            } },
        });
    }

    try {
        auto templates = common_chat_templates_init(model, "");
        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(chat_messages);
        inputs.reasoning_format = COMMON_REASONING_FORMAT_AUTO;
        if (!tool_definitions.empty()) {
            inputs.tools = common_chat_tools_parse_oaicompat(tool_definitions);
            inputs.tool_choice = COMMON_CHAT_TOOL_CHOICE_AUTO;
            inputs.parallel_tool_calls = true;
        }
        common_chat_params params = common_chat_templates_apply(templates.get(), inputs);
        local_chat_template_result result;
        result.prompt = params.prompt;
        result.grammar = params.grammar;
        result.grammar_lazy = params.grammar_lazy;
        result.grammar_triggers = params.grammar_triggers;
        result.generation_prompt = params.generation_prompt;
        result.additional_stops = params.additional_stops;
        result.parser_params = common_chat_parser_params(params);
        result.parser_params.reasoning_format = COMMON_REASONING_FORMAT_AUTO;
        if (!params.parser.empty()) {
            result.parser_params.parser.load(params.parser);
        }
        result.parser_enabled = true;
        return result;
    } catch (const std::exception & e) {
        fail(std::string("本地模型应用 GGUF Jinja 聊天模板失败：") + e.what(), error_message);
        return {};
    }
}

int32_t parse_chat_response(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    const char * generated_text,
    bool is_partial,
    std::string * output_json,
    char ** error_message
) {
    if (!model_path || !messages || message_count <= 0 || !generated_text || !output_json) {
        return fail("本地对话解析参数无效。", error_message);
    }

    std::call_once(backend_init_once, [] {
        llama_backend_init();
        ggml_backend_load_all();
    });

    llama_model_params model_params = llama_model_default_params();
    model_params.no_alloc = true;
    model_params.n_gpu_layers = 0;

    llama_model_shared_handle model = load_model(model_path, model_params, false);
    if (!model) {
        return fail("无法读取本地模型 GGUF 元数据。", error_message);
    }

    local_chat_template_result chat_template = apply_chat_template(
        model.get(),
        messages,
        message_count,
        tools,
        tool_count,
        error_message
    );
    if (chat_template.prompt.empty()) {
        return -1;
    }

    local_chat_parser_state parser_state;
    parser_state.enabled = chat_template.parser_enabled;
    parser_state.parser_params = chat_template.parser_params;
    parser_state.generated_text = generated_text;

    std::string snapshot_json;
    if (update_chat_parser_state(parser_state, is_partial, &snapshot_json) && !snapshot_json.empty()) {
        *output_json = snapshot_json;
    } else {
        *output_json = fallback_chat_message_json(generated_text);
    }
    return 0;
}

int32_t generate(
    const char * model_path,
    const char * prompt,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    const etos_local_llm_generation_config * config,
    std::string * output_text,
    std::string * output_message_json,
    etos_local_llm_token_callback token_callback,
    etos_local_llm_chat_snapshot_callback snapshot_callback,
    etos_local_llm_cancel_callback cancel_callback,
    void * user_data,
    char ** error_message
) {
    if (!model_path || ((!prompt || prompt[0] == '\0') && (!messages || message_count <= 0))) {
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

    local_chat_template_result chat_template;
    local_chat_parser_state parser_state;
    if (!prompt || prompt[0] == '\0') {
        if (should_cancel(cancel_callback, user_data)) {
            return cancelled(error_message);
        }
        chat_template = apply_chat_template(
            model.get(),
            messages,
            message_count,
            tools,
            tool_count,
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

    const llama_vocab * vocab = llama_model_get_vocab(model.get());
    std::vector<llama_token> prompt_tokens = tokenize_prompt(vocab, prompt);
    if (prompt_tokens.empty()) {
        return fail("本地模型无法解析提示词。", error_message);
    }
    if (should_cancel(cancel_callback, user_data)) {
        return cancelled(error_message);
    }

    const int32_t requested_context = std::max<int32_t>(1, generation_params.context_size);
    const int32_t requested_output = std::max<int32_t>(1, generation_params.max_output_tokens);
    const size_t prompt_token_count = prompt_tokens.size();
    if (prompt_token_count >= static_cast<size_t>(requested_context)) {
        return fail("本地模型提示词已占满上下文窗口。请缩短聊天内容或调大上下文。", error_message);
    }
    const int32_t output_limit = std::min<int32_t>(
        requested_output,
        requested_context - static_cast<int32_t>(prompt_token_count)
    );

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = requested_context;
    const int32_t decode_batch_size = generation_params.batch_size > 0
        ? std::min<int32_t>(requested_context, generation_params.batch_size)
        : static_cast<int32_t>(prompt_token_count);
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
        return fail("无法创建本地模型上下文。", error_message);
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

    bool has_pending_decode = false;
    llama_token pending_decode_token = 0;

    while (generated_tokens < output_limit) {
        if (should_cancel(cancel_callback, user_data)) {
            return cancelled(error_message);
        }
        if (has_pending_decode) {
            llama_batch token_batch = llama_batch_get_one(&pending_decode_token, 1);
            const int status = llama_decode(ctx.get(), token_batch);
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
