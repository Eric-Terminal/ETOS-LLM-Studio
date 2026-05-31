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
#include <fstream>
#include <limits>
#include <mutex>
#include <sstream>
#include <string>
#include <TargetConditionals.h>
#include <thread>
#include <utility>
#include <vector>

using json = nlohmann::ordered_json;

void string_replace_all(std::string & value, const std::string & search, const std::string & replacement) {
    if (search.empty()) {
        return;
    }
    size_t position = 0;
    while ((position = value.find(search, position)) != std::string::npos) {
        value.replace(position, search.length(), replacement);
        position += replacement.length();
    }
}

std::string common_token_to_piece(const llama_vocab * vocab, llama_token token, bool special) {
    char buffer[512];
    const int32_t written = llama_token_to_piece(vocab, token, buffer, sizeof(buffer), 0, special);
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
        special
    );
    GGML_ASSERT(dynamic_written >= 0);
    return std::string(dynamic_buffer.data(), static_cast<size_t>(dynamic_written));
}

std::string common_token_to_piece(const llama_context * ctx, llama_token token, bool special) {
    return common_token_to_piece(llama_model_get_vocab(llama_get_model(ctx)), token, special);
}

std::vector<llama_token> common_tokenize(
    const llama_vocab * vocab,
    const std::string & text,
    bool add_special,
    bool parse_special
) {
    const int32_t token_count = -llama_tokenize(
        vocab,
        text.c_str(),
        static_cast<int32_t>(text.size()),
        nullptr,
        0,
        add_special,
        parse_special
    );
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
        parse_special
    );
    if (written < 0) {
        return {};
    }
    tokens.resize(static_cast<size_t>(written));
    return tokens;
}

std::vector<llama_token> common_tokenize(
    const llama_context * ctx,
    const std::string & text,
    bool add_special,
    bool parse_special
) {
    return common_tokenize(llama_model_get_vocab(llama_get_model(ctx)), text, add_special, parse_special);
}

std::string common_detokenize(
    const llama_vocab * vocab,
    const std::vector<llama_token> & tokens,
    bool special
) {
    if (tokens.empty()) {
        return {};
    }
    std::string text;
    text.resize(tokens.size());
    int32_t written = llama_detokenize(
        vocab,
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        text.data(),
        static_cast<int32_t>(text.size()),
        false,
        special
    );
    if (written < 0) {
        text.resize(static_cast<size_t>(-written));
        written = llama_detokenize(
            vocab,
            tokens.data(),
            static_cast<int32_t>(tokens.size()),
            text.data(),
            static_cast<int32_t>(text.size()),
            false,
            special
        );
    }
    if (written < 0) {
        return {};
    }
    text.resize(static_cast<size_t>(written));
    return text;
}

std::string common_detokenize(
    const llama_context * ctx,
    const std::vector<llama_token> & tokens,
    bool special
) {
    return common_detokenize(llama_model_get_vocab(llama_get_model(ctx)), tokens, special);
}

std::string string_join(const std::vector<std::string> & values, const std::string & separator) {
    std::ostringstream result;
    for (size_t index = 0; index < values.size(); ++index) {
        if (index > 0) {
            result << separator;
        }
        result << values[index];
    }
    return result.str();
}

std::vector<std::string> string_split(const std::string & value, const std::string & delimiter) {
    std::vector<std::string> parts;
    if (delimiter.empty()) {
        parts.push_back(value);
        return parts;
    }

    size_t start = 0;
    size_t end = value.find(delimiter);
    while (end != std::string::npos) {
        parts.push_back(value.substr(start, end - start));
        start = end + delimiter.length();
        end = value.find(delimiter, start);
    }
    parts.push_back(value.substr(start));
    return parts;
}

std::string string_repeat(const std::string & value, size_t count) {
    std::string result;
    result.reserve(value.length() * count);
    for (size_t index = 0; index < count; ++index) {
        result += value;
    }
    return result;
}

bool tty_can_use_colors() {
    return false;
}

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

std::string trim_copy(const std::string & value) {
    const auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char character) {
        return std::isspace(character);
    });
    const auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char character) {
        return std::isspace(character);
    }).base();
    if (first >= last) {
        return {};
    }
    return std::string(first, last);
}

std::string lowercase_copy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

std::string normalize_option_name(std::string value) {
    while (!value.empty() && value.front() == '-') {
        value.erase(value.begin());
    }
    std::replace(value.begin(), value.end(), '_', '-');
    return lowercase_copy(value);
}

std::vector<std::string> split_arguments(const std::string & raw) {
    std::vector<std::string> result;
    std::string current;
    char quote = '\0';
    bool escaping = false;

    for (char character : raw) {
        if (escaping) {
            current.push_back(character);
            escaping = false;
            continue;
        }
        if (character == '\\') {
            escaping = true;
            continue;
        }
        if (quote != '\0') {
            if (character == quote) {
                quote = '\0';
            } else {
                current.push_back(character);
            }
            continue;
        }
        if (character == '\'' || character == '"') {
            quote = character;
            continue;
        }
        if (std::isspace(static_cast<unsigned char>(character))) {
            if (!current.empty()) {
                result.push_back(current);
                current.clear();
            }
            continue;
        }
        current.push_back(character);
    }

    if (escaping) {
        current.push_back('\\');
    }
    if (!current.empty()) {
        result.push_back(current);
    }
    return result;
}

bool parse_i32(const std::string & value, int32_t * output) {
    if (!output) {
        return false;
    }
    try {
        size_t index = 0;
        const long raw = std::stol(value, &index, 10);
        if (index != value.size()) {
            return false;
        }
        if (raw < std::numeric_limits<int32_t>::min() || raw > std::numeric_limits<int32_t>::max()) {
            return false;
        }
        *output = static_cast<int32_t>(raw);
        return true;
    } catch (...) {
        return false;
    }
}

bool parse_u32(const std::string & value, uint32_t * output) {
    int32_t signed_value = 0;
    if (!parse_i32(value, &signed_value) || signed_value < 0 || !output) {
        return false;
    }
    *output = static_cast<uint32_t>(signed_value);
    return true;
}

bool parse_float(const std::string & value, float * output) {
    if (!output) {
        return false;
    }
    try {
        size_t index = 0;
        const float raw = std::stof(value, &index);
        if (index != value.size()) {
            return false;
        }
        *output = raw;
        return true;
    } catch (...) {
        return false;
    }
}

bool read_file_text(const std::string & path, std::string * output) {
    if (!output) {
        return false;
    }
    std::ifstream stream(path);
    if (!stream) {
        return false;
    }
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    *output = buffer.str();
    return true;
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
    std::string samplers = "edskypmxt";
    std::string grammar;
    bool ignore_eos = false;
};

bool parse_advanced_arguments(
    const char * raw_arguments,
    local_generation_params * params,
    std::string * error
) {
    if (!params) {
        return false;
    }
    const std::string raw = raw_arguments ? trim_copy(raw_arguments) : "";
    if (raw.empty()) {
        return true;
    }

    const std::vector<std::string> arguments = split_arguments(raw);
    for (size_t index = 0; index < arguments.size(); ++index) {
        std::string token = arguments[index];
        if (token.empty()) {
            continue;
        }
        if (token.rfind("-", 0) != 0) {
            if (error) {
                *error = "本地高级参数必须使用 llama.cpp CLI 风格选项：" + token;
            }
            return false;
        }

        std::string raw_name = token;
        std::string value;
        const size_t equals = token.find('=');
        if (equals != std::string::npos) {
            raw_name = token.substr(0, equals);
            value = token.substr(equals + 1);
        }
        const std::string name = normalize_option_name(raw_name);

        auto next_value = [&]() -> std::string {
            if (!value.empty() || equals != std::string::npos) {
                return value;
            }
            if (index + 1 >= arguments.size()) {
                if (error) {
                    *error = "本地高级参数缺少取值：" + raw_name;
                }
                return {};
            }
            return arguments[++index];
        };

        auto set_i32 = [&](int32_t & target) -> bool {
            const std::string raw_value = next_value();
            if (raw_value.empty() && error && !error->empty()) {
                return false;
            }
            if (!parse_i32(raw_value, &target)) {
                if (error) {
                    *error = "本地高级参数整数无效：" + raw_name + " " + raw_value;
                }
                return false;
            }
            return true;
        };

        auto set_u32 = [&](uint32_t & target) -> bool {
            const std::string raw_value = next_value();
            if (raw_value.empty() && error && !error->empty()) {
                return false;
            }
            if (!parse_u32(raw_value, &target)) {
                if (error) {
                    *error = "本地高级参数整数无效：" + raw_name + " " + raw_value;
                }
                return false;
            }
            return true;
        };

        auto set_float = [&](float & target) -> bool {
            const std::string raw_value = next_value();
            if (raw_value.empty() && error && !error->empty()) {
                return false;
            }
            if (!parse_float(raw_value, &target)) {
                if (error) {
                    *error = "本地高级参数数字无效：" + raw_name + " " + raw_value;
                }
                return false;
            }
            return true;
        };

        auto set_string = [&](std::string & target) -> bool {
            target = next_value();
            return !(target.empty() && error && !error->empty());
        };

        if (name == "ctx-size" || name == "n-ctx" || name == "c") {
            if (!set_i32(params->context_size)) { return false; }
        } else if (name == "predict" || name == "n-predict" || name == "max-tokens" || name == "max-output-tokens" || name == "n") {
            if (!set_i32(params->max_output_tokens)) { return false; }
        } else if (name == "gpu-layers" || name == "n-gpu-layers" || name == "ngl") {
            if (!set_i32(params->gpu_layers)) { return false; }
        } else if (name == "seed" || name == "s") {
            if (!set_u32(params->seed)) { return false; }
        } else if (name == "temp" || name == "temperature") {
            if (!set_float(params->temperature)) { return false; }
        } else if (name == "top-k" || name == "top-k-sampling") {
            if (!set_i32(params->top_k)) { return false; }
        } else if (name == "top-p" || name == "top-p-sampling") {
            if (!set_float(params->top_p)) { return false; }
        } else if (name == "min-p") {
            if (!set_float(params->min_p)) { return false; }
        } else if (name == "min-keep") {
            if (!set_i32(params->min_keep)) { return false; }
        } else if (name == "typical" || name == "typical-p" || name == "typ-p") {
            if (!set_float(params->typical_p)) { return false; }
        } else if (name == "dynatemp-range") {
            if (!set_float(params->dynatemp_range)) { return false; }
        } else if (name == "dynatemp-exp") {
            if (!set_float(params->dynatemp_exponent)) { return false; }
        } else if (name == "xtc-probability") {
            if (!set_float(params->xtc_probability)) { return false; }
        } else if (name == "xtc-threshold") {
            if (!set_float(params->xtc_threshold)) { return false; }
        } else if (name == "top-n-sigma") {
            if (!set_float(params->top_n_sigma)) { return false; }
        } else if (name == "repeat-last-n") {
            if (!set_i32(params->repeat_last_n)) { return false; }
        } else if (name == "repeat-penalty") {
            if (!set_float(params->repeat_penalty)) { return false; }
        } else if (name == "frequency-penalty") {
            if (!set_float(params->frequency_penalty)) { return false; }
        } else if (name == "presence-penalty") {
            if (!set_float(params->presence_penalty)) { return false; }
        } else if (name == "dry-multiplier") {
            if (!set_float(params->dry_multiplier)) { return false; }
        } else if (name == "dry-base") {
            if (!set_float(params->dry_base)) { return false; }
        } else if (name == "dry-allowed-length") {
            if (!set_i32(params->dry_allowed_length)) { return false; }
        } else if (name == "dry-penalty-last-n") {
            if (!set_i32(params->dry_penalty_last_n)) { return false; }
        } else if (name == "dry-sequence-breaker") {
            const std::string breaker = next_value();
            if (breaker.empty() && error && !error->empty()) {
                return false;
            }
            if (params->dry_sequence_breakers == std::vector<std::string>({"\n", ":", "\"", "*"})) {
                params->dry_sequence_breakers.clear();
            }
            if (breaker != "none") {
                params->dry_sequence_breakers.push_back(breaker);
            }
        } else if (name == "mirostat") {
            if (!set_i32(params->mirostat)) { return false; }
        } else if (name == "mirostat-lr") {
            if (!set_float(params->mirostat_eta)) { return false; }
        } else if (name == "mirostat-ent") {
            if (!set_float(params->mirostat_tau)) { return false; }
        } else if (name == "samplers") {
            if (!set_string(params->samplers)) { return false; }
        } else if (name == "sampler-seq" || name == "sampling-seq") {
            if (!set_string(params->samplers)) { return false; }
        } else if (name == "adaptive-target") {
            if (!set_float(params->adaptive_target)) { return false; }
        } else if (name == "adaptive-decay") {
            if (!set_float(params->adaptive_decay)) { return false; }
        } else if (name == "grammar") {
            if (!set_string(params->grammar)) { return false; }
        } else if (name == "grammar-file") {
            const std::string path = next_value();
            if (path.empty() && error && !error->empty()) {
                return false;
            }
            if (!read_file_text(path, &params->grammar)) {
                if (error) {
                    *error = "无法读取本地高级参数 grammar 文件：" + path;
                }
                return false;
            }
        } else if (name == "ignore-eos") {
            params->ignore_eos = true;
        } else {
            if (error) {
                *error = "暂不支持的本地 llama.cpp CLI 参数：" + raw_name;
            }
            return false;
        }
    }

    return true;
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

    const bool looks_like_names = params.samplers.find(';') != std::string::npos
        || params.samplers.find('_') != std::string::npos
        || params.samplers.find('-') != std::string::npos;
    std::vector<std::string> samplers = looks_like_names
        ? string_split(params.samplers, ";")
        : std::vector<std::string>();
    if (!looks_like_names) {
        for (char sampler_name : params.samplers) {
            samplers.push_back(std::string(1, sampler_name));
        }
    }

    bool uses_terminal_sampler = false;
    for (std::string sampler_name : samplers) {
        sampler_name = normalize_option_name(trim_copy(sampler_name));
        if (sampler_name.empty()) {
            continue;
        }
        if (sampler_name == "e" || sampler_name == "penalties") {
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                params.repeat_last_n,
                params.repeat_penalty,
                params.frequency_penalty,
                params.presence_penalty
            ));
        } else if (sampler_name == "d" || sampler_name == "dry") {
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
        } else if (sampler_name == "s" || sampler_name == "top-n-sigma") {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_n_sigma(params.top_n_sigma));
        } else if (sampler_name == "k" || sampler_name == "top-k") {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(params.top_k));
        } else if (sampler_name == "y" || sampler_name == "typ-p" || sampler_name == "typical" || sampler_name == "typical-p") {
            llama_sampler_chain_add(sampler, llama_sampler_init_typical(params.typical_p, min_keep));
        } else if (sampler_name == "p" || sampler_name == "top-p" || sampler_name == "nucleus") {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(params.top_p, min_keep));
        } else if (sampler_name == "m" || sampler_name == "min-p") {
            llama_sampler_chain_add(sampler, llama_sampler_init_min_p(params.min_p, min_keep));
        } else if (sampler_name == "x" || sampler_name == "xtc") {
            llama_sampler_chain_add(sampler, llama_sampler_init_xtc(params.xtc_probability, params.xtc_threshold, min_keep, params.seed));
        } else if (sampler_name == "t" || sampler_name == "temp" || sampler_name == "temperature") {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp_ext(params.temperature, params.dynatemp_range, params.dynatemp_exponent));
        } else if (sampler_name == "a" || sampler_name == "adaptive-p") {
            uses_terminal_sampler = true;
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

std::string apply_chat_template(
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
        if (!role) {
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
        return params.prompt;
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
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    const char * advanced_arguments,
    std::string * output_text,
    etos_local_llm_token_callback token_callback,
    void * user_data,
    char ** error_message
) {
    if (!model_path || (!prompt && (!messages || message_count <= 0))) {
        return fail("本地推理参数无效。", error_message);
    }
    if (!output_text && !token_callback) {
        return fail("本地推理输出参数无效。", error_message);
    }

    local_generation_params generation_params;
    generation_params.context_size = std::max<int32_t>(1, context_size);
    generation_params.max_output_tokens = std::max<int32_t>(1, max_output_tokens);
    generation_params.temperature = temperature;
    generation_params.top_p = top_p;
    generation_params.gpu_layers = n_gpu_layers;
    std::string arguments_error;
    if (!parse_advanced_arguments(advanced_arguments, &generation_params, &arguments_error)) {
        return fail(arguments_error, error_message);
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

    llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (!model) {
        return fail("无法加载本地模型权重。", error_message);
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    std::string templated_prompt;
    if (!prompt) {
        templated_prompt = apply_chat_template(
            model,
            messages,
            message_count,
            tools,
            tool_count,
            nullptr,
            error_message
        );
        if (templated_prompt.empty()) {
            llama_model_free(model);
            return -1;
        }
        prompt = templated_prompt.c_str();
    }

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
    std::string prompt = apply_chat_template(
        model,
        messages,
        message_count,
        tools,
        tool_count,
        &parser_params,
        error_message
    );
    llama_model_free(model);
    if (prompt.empty()) {
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
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    const char * advanced_arguments,
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
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        advanced_arguments,
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
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    const char * advanced_arguments,
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
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        advanced_arguments,
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
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    const char * advanced_arguments,
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
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        advanced_arguments,
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
    int32_t context_size,
    int32_t max_output_tokens,
    float temperature,
    float top_p,
    int32_t n_gpu_layers,
    const char * advanced_arguments,
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
        context_size,
        max_output_tokens,
        temperature,
        top_p,
        n_gpu_layers,
        advanced_arguments,
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
