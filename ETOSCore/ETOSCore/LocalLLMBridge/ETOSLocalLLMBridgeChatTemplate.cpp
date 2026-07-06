// ============================================================================
// ETOSLocalLLMBridgeChatTemplate.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 聊天模板与工具调用响应解析。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"

#include "nlohmann/json.hpp"

#include <utility>

using json = nlohmann::ordered_json;

namespace etos_local_llm_bridge {
namespace {

struct parsed_chat_template_payload {
    json messages = json::array();
    json tools = json::array();
};

std::string role_for_message(const json & message) {
    if (!message.is_object() || !message.contains("role") || !message.at("role").is_string()) {
        return "";
    }
    return message.at("role").get<std::string>();
}

std::string next_local_tool_call_id(local_chat_parser_state & state) {
    return "local_tool_" + std::to_string(state.next_tool_call_index++);
}

json normalized_messages_for_template(const json & messages) {
    json normalized = json::array();
    std::vector<std::string> system_contents;

    for (const auto & message : messages) {
        if (role_for_message(message) == "system") {
            if (message.contains("content") && message.at("content").is_string()) {
                const std::string content = message.at("content").get<std::string>();
                if (!content.empty()) {
                    system_contents.push_back(content);
                }
            }
            continue;
        }
        normalized.push_back(message);
    }

    if (!system_contents.empty()) {
        std::string merged_system_content;
        for (size_t index = 0; index < system_contents.size(); ++index) {
            if (index > 0) {
                merged_system_content.append("\n\n");
            }
            merged_system_content.append(system_contents[index]);
        }
        json system_message = {
            { "role", "system" },
            { "content", merged_system_content },
        };
        normalized.insert(normalized.begin(), system_message);
    }
    return normalized;
}

void drop_leading_non_user_messages(json & messages) {
    if (!messages.is_array() || messages.empty()) {
        return;
    }

    size_t start = role_for_message(messages.front()) == "system" ? 1 : 0;
    while (start < messages.size() && role_for_message(messages[start]) != "user") {
        messages.erase(messages.begin() + static_cast<json::difference_type>(start));
    }
}

bool remove_oldest_conversation_turn(json & messages) {
    if (!messages.is_array() || messages.empty()) {
        return false;
    }

    const size_t start = role_for_message(messages.front()) == "system" ? 1 : 0;
    if (start >= messages.size() || role_for_message(messages[start]) != "user") {
        return false;
    }

    size_t next_user = messages.size();
    for (size_t index = start + 1; index < messages.size(); ++index) {
        if (role_for_message(messages[index]) == "user") {
            next_user = index;
            break;
        }
    }
    if (next_user >= messages.size()) {
        return false;
    }

    messages.erase(
        messages.begin() + static_cast<json::difference_type>(start),
        messages.begin() + static_cast<json::difference_type>(next_user)
    );
    return true;
}

bool parse_chat_template_payload(
    const char * messages_json,
    const char * tools_json,
    parsed_chat_template_payload & payload,
    char ** error_message
) {
    if (!messages_json || messages_json[0] == '\0') {
        fail("本地对话消息为空。", error_message);
        return false;
    }

    try {
        json chat_messages = json::parse(messages_json);
        if (!chat_messages.is_array() || chat_messages.empty()) {
            fail("本地对话消息为空。", error_message);
            return false;
        }

        json tool_definitions = json::array();
        if (tools_json && tools_json[0] != '\0') {
            tool_definitions = json::parse(tools_json);
            if (!tool_definitions.is_array()) {
                fail("本地工具定义 JSON 必须是数组。", error_message);
                return false;
            }
        }

        payload.messages = normalized_messages_for_template(chat_messages);
        drop_leading_non_user_messages(payload.messages);
        payload.tools = std::move(tool_definitions);
        return true;
    } catch (const std::exception & e) {
        fail(std::string("本地模型应用 GGUF Jinja 聊天模板失败：") + e.what(), error_message);
        return false;
    }
}

std::vector<std::string> media_ids_for_messages(const json & messages);

local_chat_template_result render_chat_template(
    const llama_model * model,
    const parsed_chat_template_payload & payload,
    const std::map<std::string, std::string> & chat_template_kwargs,
    char ** error_message
) {
    try {
        auto templates = common_chat_templates_init(model, "");
        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(payload.messages);
        inputs.reasoning_format = COMMON_REASONING_FORMAT_AUTO;
        inputs.chat_template_kwargs = chat_template_kwargs;
        if (const auto found = chat_template_kwargs.find("enable_thinking"); found != chat_template_kwargs.end()) {
            const json enable_thinking = json::parse(found->second);
            if (!enable_thinking.is_boolean()) {
                fail("本地对话模板参数 enable_thinking 必须是 JSON 布尔值。", error_message);
                return {};
            }
            inputs.enable_thinking = enable_thinking.get<bool>();
        }
        if (!payload.tools.empty()) {
            inputs.tools = common_chat_tools_parse_oaicompat(payload.tools);
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
        result.media_ids = media_ids_for_messages(payload.messages);
        return result;
    } catch (const std::exception & e) {
        fail(std::string("本地模型应用 GGUF Jinja 聊天模板失败：") + e.what(), error_message);
        return {};
    }
}

bool prompt_exceeds_context(
    const llama_vocab * vocab,
    const std::string & prompt,
    int32_t context_size
) {
    if (!vocab || prompt.empty() || context_size <= 1) {
        return false;
    }
    const std::vector<llama_token> tokens = tokenize_prompt(vocab, prompt);
    return !tokens.empty() && tokens.size() >= static_cast<size_t>(context_size);
}

std::vector<std::string> media_ids_for_messages(const json & messages) {
    std::vector<std::string> media_ids;
    if (!messages.is_array()) {
        return media_ids;
    }
    for (const auto & message : messages) {
        if (!message.is_object()
            || !message.contains("etos_media_ids")
            || !message.at("etos_media_ids").is_array()) {
            continue;
        }
        for (const auto & media_id : message.at("etos_media_ids")) {
            if (!media_id.is_string()) {
                continue;
            }
            const std::string value = media_id.get<std::string>();
            if (!value.empty()) {
                media_ids.push_back(value);
            }
        }
    }
    return media_ids;
}

} // namespace

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

local_chat_template_result apply_chat_template(
    const llama_model * model,
    const char * messages_json,
    const char * tools_json,
    const std::map<std::string, std::string> & chat_template_kwargs,
    char ** error_message
) {
    parsed_chat_template_payload payload;
    if (!parse_chat_template_payload(messages_json, tools_json, payload, error_message)) {
        return {};
    }

    return render_chat_template(model, payload, chat_template_kwargs, error_message);
}

local_chat_template_result apply_chat_template_fitting_context(
    const llama_model * model,
    const llama_vocab * vocab,
    const char * messages_json,
    const char * tools_json,
    const std::map<std::string, std::string> & chat_template_kwargs,
    int32_t context_size,
    char ** error_message
) {
    parsed_chat_template_payload payload;
    if (!parse_chat_template_payload(messages_json, tools_json, payload, error_message)) {
        return {};
    }

    while (true) {
        local_chat_template_result result = render_chat_template(
            model,
            payload,
            chat_template_kwargs,
            error_message
        );
        if (result.prompt.empty()) {
            return {};
        }
        if (!prompt_exceeds_context(vocab, result.prompt, context_size)) {
            return result;
        }
        if (!remove_oldest_conversation_turn(payload.messages)) {
            return result;
        }
        drop_leading_non_user_messages(payload.messages);
    }
}

int32_t parse_chat_response(
    const char * model_path,
    const char * messages_json,
    const char * tools_json,
    const char * generated_text,
    bool is_partial,
    std::string * output_json,
    char ** error_message
) {
    if (!model_path || !messages_json || messages_json[0] == '\0' || !generated_text || !output_json) {
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
        messages_json,
        tools_json,
        {},
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

} // namespace etos_local_llm_bridge
