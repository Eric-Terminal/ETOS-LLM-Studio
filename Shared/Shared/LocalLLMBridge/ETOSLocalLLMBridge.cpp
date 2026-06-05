// ============================================================================
// ETOSLocalLLMBridge.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 的极薄 C shim，避免 Swift 和 UI 感知底层 C++ 结构。
// ============================================================================

#include "ETOSLocalLLMBridge.h"

#include "chat.h"
#include "ggml-backend.h"
#include "llama.h"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <cctype>
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

using json = nlohmann::ordered_json;

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
    bool grammar_lazy = false;
    bool grammar_needs_prefill = false;
    std::vector<common_grammar_trigger> grammar_triggers;
    std::string generation_prompt;
    std::vector<std::string> additional_stops;
    bool ignore_eos = false;
};

struct local_chat_template_result {
    std::string prompt;
    std::string grammar;
    bool grammar_lazy = false;
    std::vector<common_grammar_trigger> grammar_triggers;
    std::string generation_prompt;
    std::vector<std::string> additional_stops;
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

std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool add_special = true) {
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
    bool uses_terminal_sampler = false;
    if (params.mirostat == 0) {
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
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(params.temperature));
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

        llama_sampler * grammar_sampler = params.grammar_lazy
            ? llama_sampler_init_grammar_lazy_patterns(
                vocab,
                params.grammar.c_str(),
                "root",
                trigger_patterns_c.data(),
                trigger_patterns_c.size(),
                trigger_tokens.data(),
                trigger_tokens.size()
            )
            : llama_sampler_init_grammar(vocab, params.grammar.c_str(), "root");
        if (!grammar_sampler) {
            llama_sampler_free(sampler);
            return nullptr;
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
                llama_sampler_accept(grammar_sampler, prefill_tokens[index]);
            }
        }
        llama_sampler_chain_add(sampler, grammar_sampler);
    }
    if (params.mirostat == 1) {
        llama_sampler_chain_add(sampler, llama_sampler_init_mirostat(llama_vocab_n_tokens(vocab), params.seed, params.mirostat_tau, params.mirostat_eta, 100));
    } else if (params.mirostat == 2) {
        llama_sampler_chain_add(sampler, llama_sampler_init_mirostat_v2(params.seed, params.mirostat_tau, params.mirostat_eta));
    } else if (uses_terminal_sampler) {
        llama_sampler_chain_add(sampler, llama_sampler_init_adaptive_p(params.adaptive_target, params.adaptive_decay, params.seed));
    } else if (params.temperature <= 0.0f) {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(params.seed));
    }
    return sampler;
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

bool emit_text_chunk(
    const std::string & chunk,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
    void * user_data
) {
    if (chunk.empty()) {
        return true;
    }
    if (output_text) {
        output_text->append(chunk);
    }
    return !token_callback || token_callback(chunk.c_str(), user_data) != 0;
}

bool flush_pending_text(
    std::string & pending_text,
    size_t retained_suffix_length,
    bool final_flush,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
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
            pending_text.clear();
        }
        return true;
    }

    std::string chunk = pending_text.substr(0, chunk_length);
    pending_text.erase(0, chunk_length);
    const bool should_continue = emit_text_chunk(chunk, output_text, token_callback, user_data);
    if (final_flush && !pending_text.empty()) {
        if (output_text) {
            output_text->append(pending_text);
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
    common_chat_parser_params * parser_params,
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
        if (!tool_definitions.empty()) {
            inputs.tools = common_chat_tools_parse_oaicompat(tool_definitions);
            inputs.tool_choice = COMMON_CHAT_TOOL_CHOICE_AUTO;
            inputs.parallel_tool_calls = true;
        }
        common_chat_params params = common_chat_templates_apply(templates.get(), inputs);
        if (parser_params) {
            *parser_params = common_chat_parser_params(params);
            common_peg_arena parser;
            parser.load(params.parser);
            parser_params->parser = std::move(parser);
            parser_params->reasoning_format = COMMON_REASONING_FORMAT_NONE;
        }
        local_chat_template_result result;
        result.prompt = params.prompt;
        result.grammar = params.grammar;
        result.grammar_lazy = params.grammar_lazy;
        result.grammar_triggers = params.grammar_triggers;
        result.generation_prompt = params.generation_prompt;
        result.additional_stops = params.additional_stops;
        return result;
    } catch (const std::exception & e) {
        fail(std::string("本地模型应用 GGUF Jinja 聊天模板失败：") + e.what(), error_message);
        return {};
    }
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
    etos_local_llm_token_callback token_callback,
    void * user_data,
    char ** error_message
) {
    if (!model_path || ((!prompt || prompt[0] == '\0') && (!messages || message_count <= 0))) {
        return fail("本地推理参数无效。", error_message);
    }
    if (!output_text && !token_callback) {
        return fail("本地推理输出参数无效。", error_message);
    }
    if (!config) {
        return fail("本地推理配置无效。", error_message);
    }

    local_generation_params generation_params = generation_params_from_config(*config);

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

    local_chat_template_result chat_template;
    if (!prompt || prompt[0] == '\0') {
        chat_template = apply_chat_template(
            model,
            messages,
            message_count,
            tools,
            tool_count,
            nullptr,
            error_message
        );
        if (chat_template.prompt.empty()) {
            llama_model_free(model);
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
        prompt = chat_template.prompt.c_str();
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    std::vector<llama_token> prompt_tokens = tokenize_prompt(vocab, prompt);
    if (prompt_tokens.empty()) {
        llama_model_free(model);
        return fail("本地模型无法解析提示词。", error_message);
    }

    const int32_t requested_context = std::max<int32_t>(1, generation_params.context_size);
    const int32_t requested_output = std::max<int32_t>(1, generation_params.max_output_tokens);
    const size_t prompt_token_count = prompt_tokens.size();
    if (prompt_token_count >= static_cast<size_t>(requested_context)) {
        llama_model_free(model);
        return fail("本地模型提示词已占满上下文窗口。请缩短聊天内容或调大上下文。", error_message);
    }
    const int32_t output_limit = std::min<int32_t>(
        requested_output,
        requested_context - static_cast<int32_t>(prompt_token_count)
    );

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = requested_context;
    ctx_params.n_batch = static_cast<int32_t>(prompt_token_count);
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
    std::string pending_text;
    const size_t retained_stop_suffix = longest_stop_length(generation_params.additional_stops);
    bool should_flush_pending = true;

    while (generated_tokens < output_limit) {
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

        pending_text.append(piece);
        const size_t stop_position = first_stop_position(pending_text, generation_params.additional_stops);
        if (stop_position != std::string::npos) {
            pending_text.erase(stop_position);
            should_flush_pending = flush_pending_text(
                pending_text,
                0,
                true,
                output_text,
                token_callback,
                user_data
            );
            break;
        }
        if (!flush_pending_text(
            pending_text,
            retained_stop_suffix > 0 ? retained_stop_suffix - 1 : 0,
            false,
            output_text,
            token_callback,
            user_data
        )) {
            should_flush_pending = false;
            break;
        }

        batch = llama_batch_get_one(&token, 1);
        generated_tokens += 1;
    }

    if (should_flush_pending) {
        flush_pending_text(pending_text, 0, true, output_text, token_callback, user_data);
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

int32_t parse_tool_calls(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    const char * generated_text,
    std::string * content,
    std::vector<common_chat_tool_call> * tool_calls,
    char ** error_message
) {
    if (!model_path || !messages || message_count <= 0 || !generated_text || !content || !tool_calls) {
        return fail("本地工具调用解析参数无效。", error_message);
    }

    std::call_once(backend_init_once, [] {
        llama_backend_init();
        ggml_backend_load_all();
    });

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;

    llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (!model) {
        return fail("无法加载本地模型权重以解析工具调用。", error_message);
    }

    common_chat_parser_params parser_params;
    local_chat_template_result chat_template = apply_chat_template(
        model,
        messages,
        message_count,
        tools,
        tool_count,
        &parser_params,
        error_message
    );
    llama_model_free(model);
    if (chat_template.prompt.empty()) {
        return -1;
    }

    try {
        common_chat_msg parsed = common_chat_parse(generated_text, false, parser_params);
        *content = parsed.content;
        *tool_calls = parsed.tool_calls;
        return 0;
    } catch (const std::exception &) {
        content->assign(generated_text);
        tool_calls->clear();
        return 0;
    }
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
        nullptr,
        0,
        nullptr,
        0,
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

int32_t etos_local_llm_generate_chat(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
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
        nullptr,
        messages,
        message_count,
        tools,
        tool_count,
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
        nullptr,
        0,
        nullptr,
        0,
        config,
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
    const etos_local_llm_tool * tools,
    int32_t tool_count,
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
        nullptr,
        messages,
        message_count,
        tools,
        tool_count,
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

int32_t etos_local_llm_parse_tool_calls(
    const char * model_path,
    const etos_local_llm_chat_message * messages,
    int32_t message_count,
    const etos_local_llm_tool * tools,
    int32_t tool_count,
    const char * generated_text,
    char ** content,
    etos_local_llm_tool_call ** tool_calls,
    int32_t * tool_call_count,
    char ** error_message
) {
    if (content) {
        *content = nullptr;
    }
    if (tool_calls) {
        *tool_calls = nullptr;
    }
    if (tool_call_count) {
        *tool_call_count = 0;
    }
    if (error_message) {
        *error_message = nullptr;
    }
    if (!content || !tool_calls || !tool_call_count) {
        return fail("本地工具调用解析参数无效。", error_message);
    }

    std::string parsed_content;
    std::vector<common_chat_tool_call> parsed_tool_calls;
    const int32_t status = parse_tool_calls(
        model_path,
        messages,
        message_count,
        tools,
        tool_count,
        generated_text,
        &parsed_content,
        &parsed_tool_calls,
        error_message
    );
    if (status != 0) {
        return status;
    }

    *content = copy_string(parsed_content);
    if (!*content) {
        return fail("本地工具调用正文内存分配失败。", error_message);
    }

    if (parsed_tool_calls.empty()) {
        return 0;
    }

    etos_local_llm_tool_call * copied_calls = static_cast<etos_local_llm_tool_call *>(
        std::calloc(parsed_tool_calls.size(), sizeof(etos_local_llm_tool_call))
    );
    if (!copied_calls) {
        return fail("本地工具调用内存分配失败。", error_message);
    }

    for (size_t index = 0; index < parsed_tool_calls.size(); ++index) {
        copied_calls[index].id = copy_string(parsed_tool_calls[index].id);
        copied_calls[index].name = copy_string(parsed_tool_calls[index].name);
        copied_calls[index].arguments = copy_string(parsed_tool_calls[index].arguments);
        if (!copied_calls[index].id || !copied_calls[index].name || !copied_calls[index].arguments) {
            etos_local_llm_free_tool_calls(copied_calls, static_cast<int32_t>(parsed_tool_calls.size()));
            return fail("本地工具调用内存分配失败。", error_message);
        }
    }

    *tool_calls = copied_calls;
    *tool_call_count = static_cast<int32_t>(parsed_tool_calls.size());
    return 0;
}

void etos_local_llm_free(char * pointer) {
    std::free(pointer);
}

void etos_local_llm_free_float(float * pointer) {
    std::free(pointer);
}

void etos_local_llm_free_tool_calls(etos_local_llm_tool_call * pointer, int32_t count) {
    if (!pointer) {
        return;
    }
    for (int32_t index = 0; index < count; ++index) {
        std::free(pointer[index].id);
        std::free(pointer[index].name);
        std::free(pointer[index].arguments);
    }
    std::free(pointer);
}
