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

std::string next_local_tool_call_id(local_chat_parser_state & state) {
    return "local_tool_" + std::to_string(state.next_tool_call_index++);
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
    char ** error_message
) {
    if (!messages_json || messages_json[0] == '\0') {
        fail("本地对话消息为空。", error_message);
        return {};
    }

    try {
        json chat_messages = json::parse(messages_json);
        if (!chat_messages.is_array() || chat_messages.empty()) {
            fail("本地对话消息为空。", error_message);
            return {};
        }

        json tool_definitions = json::array();
        if (tools_json && tools_json[0] != '\0') {
            tool_definitions = json::parse(tools_json);
            if (!tool_definitions.is_array()) {
                fail("本地工具定义 JSON 必须是数组。", error_message);
                return {};
            }
        }

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
