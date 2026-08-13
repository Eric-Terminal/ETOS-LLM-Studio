// ============================================================================
// ETOSLocalLLMBridgeDiagnostics.cpp
// ============================================================================
// ETOS LLM Studio
//
// llama.cpp 全局日志路由与当前线程的失败诊断捕获。
// ============================================================================

#include "ETOSLocalLLMBridgeInternal.h"

namespace etos_local_llm_bridge {
namespace {

constexpr size_t maximum_diagnostic_log_bytes = 16 * 1024;

std::once_flag log_router_once;
ggml_log_callback forwarded_log_callback = nullptr;
void * forwarded_log_user_data = nullptr;
thread_local native_log_capture * active_log_capture = nullptr;

void routed_log_callback(ggml_log_level level, const char * text, void * user_data) {
    (void) user_data;
    if (active_log_capture) {
        active_log_capture->append(level, text);
    }
    if (forwarded_log_callback && forwarded_log_callback != routed_log_callback) {
        forwarded_log_callback(level, text, forwarded_log_user_data);
    }
}

void install_log_router() {
    std::call_once(log_router_once, [] {
        llama_log_get(&forwarded_log_callback, &forwarded_log_user_data);
        llama_log_set(routed_log_callback, nullptr);
    });
}

} // namespace

native_log_capture::native_log_capture() {
    install_log_router();
    previous_ = active_log_capture;
    active_log_capture = this;
}

native_log_capture::~native_log_capture() {
    active_log_capture = previous_;
}

void native_log_capture::append(ggml_log_level level, const char * text) {
    if (!text || text[0] == '\0') {
        return;
    }

    const bool starts_diagnostic = level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR;
    if (!starts_diagnostic && !(level == GGML_LOG_LEVEL_CONT && captures_continuation_)) {
        captures_continuation_ = false;
        return;
    }

    captures_continuation_ = true;
    buffer_.append(text);
    if (buffer_.size() > maximum_diagnostic_log_bytes) {
        buffer_.erase(0, buffer_.size() - maximum_diagnostic_log_bytes);
    }
}

std::string native_log_capture::text() const {
    const size_t start = buffer_.find_first_not_of("\r\n\t ");
    if (start == std::string::npos) {
        return "";
    }
    const size_t end = buffer_.find_last_not_of("\r\n\t ");
    return buffer_.substr(start, end - start + 1);
}

void initialize_backend() {
    std::call_once(backend_init_once, [] {
        install_log_router();
        llama_backend_init();
        ggml_backend_load_all();
    });
}

std::string diagnostic_message(std::string summary, const std::string & native_log) {
    if (!native_log.empty()) {
        summary.append("\n\nllama.cpp:\n");
        summary.append(native_log);
    }
    return summary;
}

} // namespace etos_local_llm_bridge
