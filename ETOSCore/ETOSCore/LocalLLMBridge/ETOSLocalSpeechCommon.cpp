// ============================================================================
// ETOSLocalSpeechCommon.cpp
// ============================================================================
// ETOS LLM Studio
//
// 改编自 FunASR llama.cpp runtime v0.1.9（MIT）：GGUF 探测、FBank 与 FSMN-VAD。
// ============================================================================

#include "ETOSLocalSpeechInternal.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <map>

namespace etos_local_speech {
namespace {

constexpr float pre_emphasis = 0.97f;
constexpr float lowest_frequency = 20.0f;
constexpr float highest_frequency = 8000.0f;
constexpr float float_epsilon = 1.1920929e-07f;

float mel_frequency(float frequency) {
    return 1127.0f * std::log1p(frequency / 700.0f);
}

void fft(std::vector<float> & real, std::vector<float> & imaginary, int32_t count) {
    for (int32_t index = 1, reversed = 0; index < count; ++index) {
        int32_t bit = count >> 1;
        for (; reversed & bit; bit >>= 1) {
            reversed ^= bit;
        }
        reversed ^= bit;
        if (index < reversed) {
            std::swap(real[index], real[reversed]);
            std::swap(imaginary[index], imaginary[reversed]);
        }
    }

    for (int32_t length = 2; length <= count; length <<= 1) {
        const double angle = -2.0 * M_PI / length;
        const float root_real = std::cos(angle);
        const float root_imaginary = std::sin(angle);
        for (int32_t offset = 0; offset < count; offset += length) {
            float current_real = 1.0f;
            float current_imaginary = 0.0f;
            for (int32_t index = 0; index < length / 2; ++index) {
                const float upper_real = real[offset + index];
                const float upper_imaginary = imaginary[offset + index];
                const float lower_real = real[offset + index + length / 2] * current_real
                    - imaginary[offset + index + length / 2] * current_imaginary;
                const float lower_imaginary = real[offset + index + length / 2] * current_imaginary
                    + imaginary[offset + index + length / 2] * current_real;
                real[offset + index] = upper_real + lower_real;
                imaginary[offset + index] = upper_imaginary + lower_imaginary;
                real[offset + index + length / 2] = upper_real - lower_real;
                imaginary[offset + index + length / 2] = upper_imaginary - lower_imaginary;
                const float next_real = current_real * root_real - current_imaginary * root_imaginary;
                current_imaginary = current_real * root_imaginary + current_imaginary * root_real;
                current_real = next_real;
            }
        }
    }
}

std::vector<std::vector<float>> compute_mel_frames(const std::vector<float> & input) {
    if (input.size() < static_cast<size_t>(window_length)) {
        return {};
    }

    std::vector<float> waveform = input;
    for (float & sample : waveform) {
        sample *= 32768.0f;
    }

    std::vector<float> window(window_length);
    for (int32_t index = 0; index < window_length; ++index) {
        window[index] = 0.54f - 0.46f * std::cos(
            2.0f * static_cast<float>(M_PI) * index / (window_length - 1)
        );
    }

    constexpr int32_t frequency_bin_count = fft_size / 2 + 1;
    const float bin_width = static_cast<float>(sample_rate) / fft_size;
    const float mel_low = mel_frequency(lowest_frequency);
    const float mel_high = mel_frequency(highest_frequency);
    const float mel_step = (mel_high - mel_low) / (mel_count + 1);
    std::vector<std::vector<float>> filter_bank(
        mel_count,
        std::vector<float>(frequency_bin_count, 0.0f)
    );
    for (int32_t mel = 0; mel < mel_count; ++mel) {
        const float left = mel_low + mel * mel_step;
        const float center = mel_low + (mel + 1) * mel_step;
        const float right = mel_low + (mel + 2) * mel_step;
        for (int32_t bin = 0; bin < frequency_bin_count; ++bin) {
            const float frequency = mel_frequency(bin_width * bin);
            if (frequency > left && frequency < right) {
                filter_bank[mel][bin] = frequency <= center
                    ? (frequency - left) / (center - left)
                    : (right - frequency) / (right - center);
            }
        }
    }

    const int32_t frame_count = static_cast<int32_t>(
        (waveform.size() - window_length) / frame_shift + 1
    );
    std::vector<std::vector<float>> features(
        frame_count,
        std::vector<float>(mel_count)
    );
    std::vector<float> real(fft_size);
    std::vector<float> imaginary(fft_size);
    std::vector<float> frame(window_length);
    for (int32_t time = 0; time < frame_count; ++time) {
        const float * samples = waveform.data() + time * frame_shift;
        double mean = 0.0;
        for (int32_t index = 0; index < window_length; ++index) {
            mean += samples[index];
        }
        mean /= window_length;
        for (int32_t index = 0; index < window_length; ++index) {
            frame[index] = samples[index] - static_cast<float>(mean);
        }
        for (int32_t index = window_length - 1; index > 0; --index) {
            frame[index] -= pre_emphasis * frame[index - 1];
        }
        frame[0] -= pre_emphasis * frame[0];
        for (int32_t index = 0; index < fft_size; ++index) {
            real[index] = index < window_length ? frame[index] * window[index] : 0.0f;
            imaginary[index] = 0.0f;
        }
        fft(real, imaginary, fft_size);
        for (int32_t mel = 0; mel < mel_count; ++mel) {
            float energy = 0.0f;
            for (int32_t bin = 0; bin < frequency_bin_count; ++bin) {
                if (filter_bank[mel][bin] > 0.0f) {
                    energy += filter_bank[mel][bin]
                        * (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]);
                }
            }
            features[time][mel] = std::log(std::max(energy, float_epsilon));
        }
    }
    return features;
}

std::vector<float> apply_lfr(
    const std::vector<std::vector<float>> & features,
    int32_t window,
    int32_t stride,
    int32_t & output_frames
) {
    const int32_t input_frames = static_cast<int32_t>(features.size());
    if (input_frames == 0) {
        output_frames = 0;
        return {};
    }

    const int32_t padding = (window - 1) / 2;
    output_frames = (input_frames + stride - 1) / stride;
    std::vector<std::vector<float>> padded;
    padded.reserve(input_frames + padding + window);
    for (int32_t index = 0; index < padding; ++index) {
        padded.push_back(features.front());
    }
    padded.insert(padded.end(), features.begin(), features.end());
    while (static_cast<int32_t>(padded.size()) < (output_frames - 1) * stride + window) {
        padded.push_back(features.back());
    }

    std::vector<float> output(
        static_cast<size_t>(output_frames) * window * mel_count
    );
    for (int32_t time = 0; time < output_frames; ++time) {
        for (int32_t index = 0; index < window; ++index) {
            std::memcpy(
                output.data() + (static_cast<size_t>(time) * window + index) * mel_count,
                padded[time * stride + index].data(),
                mel_count * sizeof(float)
            );
        }
    }
    return output;
}

struct vad_model {
    ggml_context * weights_context = nullptr;
    std::map<std::string, ggml_tensor *> tensors;

    ~vad_model() {
        if (weights_context) {
            ggml_free(weights_context);
        }
    }

    ggml_tensor * required(const std::string & name) const {
        const auto iterator = tensors.find(name);
        if (iterator == tensors.end() || !iterator->second) {
            throw std::runtime_error("FSMN-VAD 模型缺少张量：" + name);
        }
        return iterator->second;
    }
};

std::vector<speech_segment> run_vad(
    const std::string & model_path,
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    vad_model model;
    gguf_init_params init_params = {false, &model.weights_context};
    gguf_context * gguf = gguf_init_from_file(model_path.c_str(), init_params);
    if (!gguf) {
        throw std::runtime_error("无法加载 FSMN-VAD GGUF 模型。");
    }
    const auto read_integer = [&](const char * key, int32_t fallback) {
        const int64_t index = gguf_find_key(gguf, key);
        return index < 0 ? fallback : static_cast<int32_t>(gguf_get_val_u32(gguf, index));
    };
    const int32_t input_dimension = read_integer("vad.input_dim", 400);
    const int32_t projection_dimension = read_integer("vad.proj_dim", 128);
    const int32_t layer_count = read_integer("vad.fsmn_layers", 4);
    const int32_t left_order = read_integer("vad.lorder", 20);
    const int32_t output_dimension = read_integer("vad.output_dim", 248);
    const int32_t lfr_m = read_integer("vad.lfr_m", 5);
    const int32_t lfr_n = read_integer("vad.lfr_n", 1);
    for (int64_t index = 0; index < gguf_get_n_tensors(gguf); ++index) {
        const char * name = gguf_get_tensor_name(gguf, index);
        model.tensors[name] = ggml_get_tensor(model.weights_context, name);
    }
    gguf_free(gguf);

    int32_t frame_count = 0;
    std::vector<float> features = apply_lfr(
        compute_mel_frames(waveform),
        lfr_m,
        lfr_n,
        frame_count
    );
    if (frame_count == 0) {
        return {};
    }
    float * shift = static_cast<float *>(model.required("cmvn.shift")->data);
    float * scale = static_cast<float *>(model.required("cmvn.scale")->data);
    for (int32_t time = 0; time < frame_count; ++time) {
        for (int32_t dimension = 0; dimension < input_dimension; ++dimension) {
            const size_t offset = static_cast<size_t>(time) * input_dimension + dimension;
            features[offset] = (features[offset] + shift[dimension]) * scale[dimension];
        }
    }

    throw_if_cancelled(options);
    ggml_backend_t backend = ggml_backend_cpu_init();
    if (!backend) {
        throw std::runtime_error("无法初始化 FSMN-VAD CPU 后端。");
    }
    ggml_init_params graph_params = {
        static_cast<size_t>(32) * 1024 * 1024,
        nullptr,
        true
    };
    ggml_context * context = ggml_init(graph_params);
    if (!context) {
        ggml_backend_free(backend);
        throw std::runtime_error("无法创建 FSMN-VAD 计算图。");
    }
    ggml_tensor * input = ggml_new_tensor_2d(
        context,
        GGML_TYPE_F32,
        input_dimension,
        frame_count
    );
    ggml_set_input(input);
    ggml_tensor * hidden = linear(
        context,
        model.required("encoder.in_linear1.linear.weight"),
        model.required("encoder.in_linear1.linear.bias"),
        input
    );
    hidden = linear(
        context,
        model.required("encoder.in_linear2.linear.weight"),
        model.required("encoder.in_linear2.linear.bias"),
        hidden
    );
    hidden = ggml_relu(context, hidden);
    for (int32_t layer = 0; layer < layer_count; ++layer) {
        const std::string prefix = "encoder.fsmn." + std::to_string(layer) + ".";
        ggml_tensor * projected = ggml_mul_mat(
            context,
            model.required(prefix + "linear.linear.weight"),
            hidden
        );
        ggml_tensor * kernel = model.required(prefix + "fsmn_block.conv_left.weight");
        ggml_tensor * padded = ggml_pad_ext(
            context,
            projected,
            0,
            0,
            left_order - 1,
            0,
            0,
            0,
            0,
            0
        );
        ggml_tensor * accumulated = projected;
        for (int32_t tap = 0; tap < left_order; ++tap) {
            ggml_tensor * slice = ggml_view_2d(
                context,
                padded,
                projection_dimension,
                frame_count,
                padded->nb[1],
                static_cast<size_t>(tap) * padded->nb[1]
            );
            ggml_tensor * weight = ggml_view_1d(
                context,
                kernel,
                projection_dimension,
                static_cast<size_t>(tap) * kernel->nb[1]
            );
            accumulated = ggml_add(
                context,
                accumulated,
                ggml_mul(context, slice, weight)
            );
        }
        hidden = linear(
            context,
            model.required(prefix + "affine.linear.weight"),
            model.required(prefix + "affine.linear.bias"),
            accumulated
        );
        hidden = ggml_relu(context, hidden);
    }
    hidden = linear(
        context,
        model.required("encoder.out_linear1.linear.weight"),
        model.required("encoder.out_linear1.linear.bias"),
        hidden
    );
    hidden = linear(
        context,
        model.required("encoder.out_linear2.linear.weight"),
        model.required("encoder.out_linear2.linear.bias"),
        hidden
    );
    hidden = ggml_soft_max(context, hidden);
    ggml_set_output(hidden);

    ggml_cgraph * graph = ggml_new_graph(context);
    ggml_build_forward_expand(graph, hidden);
    ggml_gallocr_t allocator = ggml_gallocr_new(ggml_backend_cpu_buffer_type());
    ggml_gallocr_alloc_graph(allocator, graph);
    ggml_backend_tensor_set(input, features.data(), 0, ggml_nbytes(input));
    ggml_backend_cpu_set_n_threads(backend, options.threads);
    const bool computed = ggml_backend_graph_compute(backend, graph) == GGML_STATUS_SUCCESS;
    std::vector<float> scores(static_cast<size_t>(output_dimension) * frame_count);
    if (computed) {
        ggml_backend_tensor_get(hidden, scores.data(), 0, ggml_nbytes(hidden));
    }
    ggml_gallocr_free(allocator);
    ggml_free(context);
    ggml_backend_free(backend);
    if (!computed) {
        throw std::runtime_error("FSMN-VAD 推理失败。");
    }
    throw_if_cancelled(options);

    constexpr int32_t frame_milliseconds = 10;
    constexpr int32_t window_frames = 20;
    constexpr int32_t speech_threshold = 15;
    constexpr int32_t end_lookahead = 10;
    const int32_t maximum_segment_frames = std::max(
        1,
        options.vad_max_segment_milliseconds / frame_milliseconds
    );
    const int32_t start_lookback = window_frames + 20;
    std::vector<int32_t> window(window_frames, 0);
    std::vector<speech_segment> segments;
    int32_t window_position = 0;
    int32_t speech_sum = 0;
    int32_t previous_state = 0;
    int32_t state = 0;
    int32_t candidate_start = -1;
    int32_t silence_frames = 0;
    int32_t previous_end = 0;
    int32_t accumulated_milliseconds = 0;
    int32_t max_end_silence = 0;
    int32_t end_lookback = 0;

    const auto recompute_silence = [&] {
        int32_t silence_milliseconds;
        if (accumulated_milliseconds <= 10000) silence_milliseconds = 2000;
        else if (accumulated_milliseconds <= 20000) silence_milliseconds = 1000;
        else if (accumulated_milliseconds <= 30000) silence_milliseconds = 800;
        else if (accumulated_milliseconds <= 40000) silence_milliseconds = 600;
        else if (accumulated_milliseconds <= 50000) silence_milliseconds = 400;
        else if (accumulated_milliseconds <= 60000) silence_milliseconds = 200;
        else silence_milliseconds = 100;
        max_end_silence = std::max(0, silence_milliseconds - 150) / frame_milliseconds;
        end_lookback = std::max(0, max_end_silence - end_lookahead - 1);
    };
    recompute_silence();

    const auto emit = [&](int32_t start, int32_t end) {
        start = std::max(start, previous_end);
        start = std::max(start, 0);
        end = std::min(end, frame_count);
        if (end > start) {
            segments.push_back({start, end});
            previous_end = end;
        }
    };
    bool speech_latched = false;
    const auto reset = [&] {
        std::fill(window.begin(), window.end(), 0);
        window_position = 0;
        speech_sum = 0;
        previous_state = 0;
        silence_frames = 0;
        state = 0;
        candidate_start = -1;
        accumulated_milliseconds = 0;
        speech_latched = false;
    };

    constexpr int32_t chunk_frames = 6000;
    for (int32_t time = 0; time < frame_count; ++time) {
        if (time > 0 && time % chunk_frames == 0) {
            if (state == 1 || speech_latched) {
                accumulated_milliseconds += 60000;
                speech_latched = true;
            }
            recompute_silence();
        }
        const float silence_score = scores[static_cast<size_t>(time) * output_dimension];
        const int32_t is_speech = (1.0f - silence_score >= silence_score + 0.5f) ? 1 : 0;
        speech_sum -= window[window_position];
        speech_sum += is_speech;
        window[window_position] = is_speech;
        window_position = (window_position + 1) % window_frames;

        int32_t change;
        if (previous_state == 0 && speech_sum >= speech_threshold) {
            previous_state = 1;
            change = 3;
        } else if (previous_state == 1 && speech_sum <= speech_threshold) {
            previous_state = 0;
            change = 1;
        } else {
            change = previous_state == 0 ? 0 : 2;
        }

        if (change == 3) {
            silence_frames = 0;
            if (state == 0) {
                candidate_start = std::max(
                    previous_end,
                    std::max(0, time - start_lookback)
                );
                state = 1;
            } else if (time - candidate_start + 1 > maximum_segment_frames) {
                emit(candidate_start, time);
                reset();
            }
        } else if (change == 1 || change == 2) {
            silence_frames = 0;
            if (state == 1 && time - candidate_start + 1 > maximum_segment_frames) {
                emit(candidate_start, time);
                reset();
            }
        } else {
            ++silence_frames;
            if (state == 1) {
                if (silence_frames >= max_end_silence) {
                    emit(candidate_start, time - end_lookback);
                    reset();
                } else if (time - candidate_start + 1 > maximum_segment_frames) {
                    emit(candidate_start, time);
                    reset();
                }
            }
        }
    }
    if (state == 1) {
        emit(candidate_start, frame_count);
    }
    for (speech_segment & segment : segments) {
        segment.first *= frame_milliseconds;
        segment.second *= frame_milliseconds;
    }
    return segments;
}

} // namespace

architecture architecture_from_name(const std::string & name) {
    if (name == "sensevoice-small") {
        return architecture::sense_voice;
    }
    if (name == "paraformer") {
        return architecture::paraformer;
    }
    if (name == "funasr-sensevoice-encoder") {
        return architecture::fun_asr_nano_encoder;
    }
    if (name == "fsmn-vad") {
        return architecture::fsmn_vad;
    }
    return architecture::unknown;
}

std::string architecture_name(const std::string & model_path) {
    gguf_init_params params = {true, nullptr};
    gguf_context * context = gguf_init_from_file(model_path.c_str(), params);
    if (!context) {
        throw std::runtime_error("无法读取 GGUF 模型元数据。");
    }
    const int64_t key = gguf_find_key(context, "general.architecture");
    if (key < 0) {
        gguf_free(context);
        throw std::runtime_error("GGUF 模型缺少 general.architecture。");
    }
    const char * raw_value = gguf_get_val_str(context, key);
    const std::string result = raw_value ? raw_value : "";
    gguf_free(context);
    if (result.empty()) {
        throw std::runtime_error("GGUF 模型架构为空。");
    }
    return result;
}

std::vector<float> compute_fbank(const std::vector<float> & waveform, int32_t & frame_count) {
    return apply_lfr(
        compute_mel_frames(waveform),
        lfr_window,
        lfr_stride,
        frame_count
    );
}

void add_positional_encoding(
    std::vector<float> & values,
    int32_t frame_count,
    int32_t depth
) {
    const double increment = std::log(10000.0) / (depth / 2.0 - 1.0);
    for (int32_t time = 0; time < frame_count; ++time) {
        const double position = time + 1;
        for (int32_t index = 0; index < depth / 2; ++index) {
            const double inverse_timescale = std::exp(index * -increment);
            const double scaled_time = position * inverse_timescale;
            values[static_cast<size_t>(time) * depth + index] += std::sin(scaled_time);
            values[static_cast<size_t>(time) * depth + depth / 2 + index] += std::cos(scaled_time);
        }
    }
}

std::vector<speech_segment> speech_segments(
    const std::vector<float> & waveform,
    const transcription_options & options
) {
    if (options.vad_model_path.empty()) {
        return {{0, static_cast<int32_t>(waveform.size())}};
    }
    const std::vector<speech_segment> millisecond_segments = run_vad(
        options.vad_model_path,
        waveform,
        options
    );
    std::vector<speech_segment> sample_segments;
    sample_segments.reserve(millisecond_segments.size());
    const int64_t sample_count = static_cast<int64_t>(waveform.size());
    for (const speech_segment & segment : millisecond_segments) {
        const int64_t start = static_cast<int64_t>(segment.first) * sample_rate / 1000;
        const int64_t end = static_cast<int64_t>(segment.second) * sample_rate / 1000;
        sample_segments.push_back({
            static_cast<int32_t>(std::clamp<int64_t>(start, 0, sample_count)),
            static_cast<int32_t>(std::clamp<int64_t>(end, 0, sample_count))
        });
    }
    return sample_segments;
}

void append_segment_text(std::string & destination, const std::string & segment) {
    const std::string normalized = trimmed(segment);
    if (normalized.empty()) {
        return;
    }
    if (!destination.empty()) {
        const unsigned char previous = destination.back();
        const unsigned char next = normalized.front();
        if (std::isalnum(previous) && std::isalnum(next)) {
            destination.push_back(' ');
        }
    }
    destination += normalized;
}

void throw_if_cancelled(const transcription_options & options) {
    if (etos_local_llm_bridge::should_cancel(options.cancel_callback, options.user_data)) {
        throw std::runtime_error("本地语音转写已取消。");
    }
}

void clear_speech_model_cache() {
    clear_sense_voice_cache();
    clear_paraformer_cache();
    clear_fun_asr_nano_cache();
}

} // namespace etos_local_speech
