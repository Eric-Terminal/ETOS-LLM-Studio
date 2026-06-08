// ============================================================================
// ETOSLocalLLMBridgeGenerationSupport.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 本地文本生成的采样、分词和流式文本辅助逻辑。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"

#include <cctype>
#include <cmath>

namespace etos_local_llm_bridge {
namespace {

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

} // namespace

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
    params.chat_template_kwargs.clear();
    for (int32_t index = 0;
         config.chat_template_kwarg_keys
            && config.chat_template_kwarg_values
            && index < config.chat_template_kwarg_count;
         ++index) {
        const char * key = config.chat_template_kwarg_keys[index];
        const char * value = config.chat_template_kwarg_values[index];
        if (key && key[0] != '\0' && value) {
            params.chat_template_kwargs[key] = value;
        }
    }
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

} // namespace etos_local_llm_bridge
