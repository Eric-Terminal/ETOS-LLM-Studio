// ============================================================================
// ETOSLocalSpeechInternal.h
// ============================================================================
// ETOS LLM Studio
//
// FunASR GGUF 本地语音运行时的内部共享接口。
// ============================================================================

#ifndef ETOS_LOCAL_SPEECH_INTERNAL_H
#define ETOS_LOCAL_SPEECH_INTERNAL_H

#include "ETOSLocalLLMBridgeInternal.h"
#include "ggml-alloc.h"
#include "ggml-cpu.h"
#include "gguf.h"

#include <cmath>
#include <functional>
#include <stdexcept>
#include <utility>

namespace etos_local_speech {

constexpr int32_t sample_rate = 16000;
constexpr int32_t window_length = 400;
constexpr int32_t frame_shift = 160;
constexpr int32_t fft_size = 512;
constexpr int32_t mel_count = 80;
constexpr int32_t lfr_window = 7;
constexpr int32_t lfr_stride = 6;
constexpr int32_t feature_dimension = mel_count * lfr_window;
constexpr float layer_norm_epsilon = 1e-5f;

enum class architecture {
    unknown,
    sense_voice,
    paraformer,
    fun_asr_nano_encoder,
    fsmn_vad,
};

struct transcription_options {
    std::string decoder_model_path;
    std::string vad_model_path;
    int32_t context_size = 2048;
    int32_t max_output_tokens = 512;
    int32_t gpu_layers = -1;
    int32_t threads = 4;
    int32_t chunk_seconds = 15;
    int32_t vad_max_segment_milliseconds = 30000;
    bool use_model_cache = true;
    etos_local_llm_cancel_callback cancel_callback = nullptr;
    void * user_data = nullptr;
};

using speech_segment = std::pair<int32_t, int32_t>;

architecture architecture_from_name(const std::string & name);
std::string architecture_name(const std::string & model_path);
void validate_lora_adapter(const std::string & adapter_path, const std::string & expected_architecture);
std::vector<float> compute_fbank(const std::vector<float> & waveform, int32_t & frame_count);
void add_positional_encoding(std::vector<float> & values, int32_t frame_count, int32_t depth);
std::vector<speech_segment> speech_segments(
    const std::vector<float> & waveform,
    const transcription_options & options
);
void append_segment_text(std::string & destination, const std::string & segment);
void throw_if_cancelled(const transcription_options & options);

std::string transcribe_sense_voice(
    const std::string & model_path,
    const std::vector<float> & waveform,
    const transcription_options & options
);
std::string transcribe_paraformer(
    const std::string & model_path,
    const std::vector<float> & waveform,
    const transcription_options & options
);
std::string transcribe_fun_asr_nano(
    const std::string & encoder_model_path,
    const std::vector<float> & waveform,
    const transcription_options & options
);

void clear_sense_voice_cache();
void clear_paraformer_cache();
void clear_fun_asr_nano_cache();
void clear_speech_model_cache();

inline ggml_tensor * linear(
    ggml_context * context,
    ggml_tensor * weights,
    ggml_tensor * bias,
    ggml_tensor * input
) {
    if (!weights || !input) {
        throw std::runtime_error("语音模型缺少线性层权重。");
    }
    ggml_tensor * output = ggml_mul_mat(context, weights, input);
    return bias ? ggml_add(context, output, bias) : output;
}

inline ggml_tensor * layer_norm(
    ggml_context * context,
    ggml_tensor * input,
    ggml_tensor * weights,
    ggml_tensor * bias
) {
    if (!input || !weights || !bias) {
        throw std::runtime_error("语音模型缺少归一化层权重。");
    }
    return ggml_add(
        context,
        ggml_mul(context, ggml_norm(context, input, layer_norm_epsilon), weights),
        bias
    );
}

inline std::string trimmed(const std::string & value) {
    const size_t first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return {};
    }
    const size_t last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}

} // namespace etos_local_speech

#endif
