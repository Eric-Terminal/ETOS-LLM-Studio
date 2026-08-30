// ============================================================================
// TTSManagerHTTPSynthesis.swift
// ============================================================================
// ETOS LLM Studio
//
// 将各家 HTTP TTS 协议收敛为统一的 AudioClip，播放层不感知供应商差异。
// ============================================================================

import Foundation

extension TTSManager {
    var cloudRequestTimeoutSeconds: TimeInterval {
#if os(watchOS)
        25
#else
        120
#endif
    }

    func synthesizeCloudAudio(
        text: String,
        settings _: TTSSettingsSnapshot,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        switch service.providerKind {
        case .openAICompatible, .groq:
            return try await synthesizeOpenAISpeech(text: text, service: service)
        case .gemini:
            return try await synthesizeGemini(text: text, service: service)
        case .azure:
            return try await synthesizeAzure(text: text, service: service)
        case .qwen:
            return try await synthesizeQwen(text: text, service: service)
        case .qwenAudio:
            return try await synthesizeQwenAudio(text: text, service: service)
        case .miniMax:
            return try await synthesizeMiniMax(text: text, service: service)
        case .xAI:
            return try await synthesizeXAI(text: text, service: service)
        case .elevenLabs:
            return try await synthesizeElevenLabs(text: text, service: service)
        case .miMo:
            return try await synthesizeMiMo(text: text, service: service)
        case .stepFun:
            return try await synthesizeStepFun(text: text, service: service)
        case .fishAudio:
            return try await synthesizeFishAudio(text: text, service: service)
        }
    }

    private func synthesizeOpenAISpeech(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let url = normalizedBaseURL(service.trimmedBaseURL).appendingPathComponent("audio/speech")
        let responseFormat = service.responseFormat.isEmpty
            ? (service.providerKind == .groq ? "wav" : "mp3")
            : service.responseFormat
        let payload: [String: Any] = [
            "model": service.trimmedModelID,
            "input": text,
            "voice": service.trimmedVoice,
            "response_format": responseFormat
        ]
        let data = try await fetchJSONAudio(
            url: url,
            apiKey: service.trimmedAPIKey,
            payload: payload
        )
        return AudioClip(data: data, format: responseFormat.lowercased(), sampleRate: nil)
    }

    private func synthesizeGemini(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let baseURL = normalizedBaseURL(service.trimmedBaseURL)
            .absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(baseURL)/models/\(service.trimmedModelID):generateContent")!
        let payload: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": text]]
            ]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": service.trimmedVoice]
                    ]
                ]
            ],
            "model": service.trimmedModelID
        ]

        var request = try jsonRequest(url: url, payload: payload)
        request.setValue(service.trimmedAPIKey, forHTTPHeaderField: "x-goog-api-key")
        let data = try await fetchData(for: request)
        let pcmData = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let inlineData = parts.first?["inlineData"] as? [String: Any],
                  let base64 = inlineData["data"] as? String else { return nil }
            return Data(base64Encoded: base64)
        }.value
        guard let pcmData else {
            throw ttsError(code: -4, message: NSLocalizedString("Gemini TTS 响应解析失败。", comment: ""))
        }
        return AudioClip(data: pcmData, format: "pcm", sampleRate: 24_000)
    }

    private func synthesizeAzure(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let configuredBaseURL = normalizedBaseURL(service.trimmedBaseURL)
        let baseURL = URL(string: configuredBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
        let suffix = "/cognitiveservices/v1"
        let url: URL
        if baseURL.path.lowercased().hasSuffix(suffix) {
            url = baseURL
        } else {
            url = baseURL
                .appendingPathComponent("cognitiveservices")
                .appendingPathComponent("v1")
        }
        let language = service.languageType.isEmpty ? "zh-CN" : service.languageType
        let body = """
        <speak version="1.0" xml:lang="\(language.xmlAttributeEscaped)"><voice name="\(service.trimmedVoice.xmlAttributeEscaped)">\(text.xmlTextEscaped)</voice></speak>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = cloudRequestTimeoutSeconds
        request.setValue(service.trimmedAPIKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-96kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("ETOS LLM Studio", forHTTPHeaderField: "User-Agent")
        request.httpBody = body.data(using: .utf8)
        return AudioClip(data: try await fetchData(for: request), format: "mp3", sampleRate: 24_000)
    }

    private func synthesizeQwen(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let url = normalizedBaseURL(service.trimmedBaseURL)
            .appendingPathComponent("services")
            .appendingPathComponent("aigc")
            .appendingPathComponent("multimodal-generation")
            .appendingPathComponent("generation")
        let payload: [String: Any] = [
            "model": service.trimmedModelID,
            "input": [
                "text": text,
                "voice": service.trimmedVoice,
                "language_type": service.languageType
            ]
        ]
        var request = try jsonRequest(url: url, payload: payload)
        request.setValue("Bearer \(service.trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        let data = try await fetchData(for: request)
        let output = await Task.detached(priority: .userInitiated) {
            var output = Data()
            for payload in Self.parseSSEPayloads(from: data) {
                guard let json = Self.jsonObject(from: payload),
                      let outputObject = json["output"] as? [String: Any],
                      let audio = outputObject["audio"] as? [String: Any],
                      let base64 = audio["data"] as? String,
                      let chunk = Data(base64Encoded: base64) else { continue }
                output.append(chunk)
            }
            return output
        }.value
        guard !output.isEmpty else {
            throw ttsError(code: -5, message: NSLocalizedString("Qwen TTS 未返回可播放音频。", comment: ""))
        }
        return AudioClip(data: output, format: "pcm", sampleRate: 24_000)
    }

    private func synthesizeMiniMax(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let parameters = service.advancedSettings
        let url = normalizedBaseURL(service.trimmedBaseURL).appendingPathComponent("t2a_v2")
        var voiceSettings: [String: Any] = [
            "voice_id": service.trimmedVoice,
            "speed": parameters.speed,
            "vol": parameters.volume,
            "pitch": parameters.pitch
        ]
        if !service.miniMaxEmotion.isEmpty {
            voiceSettings["emotion"] = service.miniMaxEmotion
        }
        var payload: [String: Any] = [
            "model": service.trimmedModelID,
            "text": text,
            "stream": true,
            "output_format": "hex",
            "stream_options": ["exclude_aggregated_audio": true],
            "voice_setting": voiceSettings,
            "audio_setting": [
                "sample_rate": parameters.sampleRate,
                "bitrate": parameters.bitrate,
                "format": service.responseFormat,
                "channel": parameters.channels
            ],
            "subtitle_enable": parameters.subtitleEnabled
        ]
        if !parameters.languageBoost.isEmpty {
            payload["language_boost"] = parameters.languageBoost
        }
        if !parameters.pronunciationDictionary.isEmpty {
            payload["pronunciation_dict"] = ["tone": parameters.pronunciationDictionary]
        }
        var request = try jsonRequest(url: url, payload: payload)
        request.setValue("Bearer \(service.trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let data = try await fetchData(for: request)
        let output = await Task.detached(priority: .userInitiated) {
            var output = Data()
            for payload in Self.parseSSEPayloads(from: data) {
                guard let json = Self.jsonObject(from: payload),
                      let responseData = json["data"] as? [String: Any],
                      let hex = responseData["audio"] as? String,
                      let chunk = Data(ttsHexString: hex) else { continue }
                output.append(chunk)
            }
            return output
        }.value
        guard !output.isEmpty else {
            throw ttsError(code: -6, message: NSLocalizedString("MiniMax TTS 未返回可播放音频。", comment: ""))
        }
        return AudioClip(
            data: output,
            format: service.responseFormat.lowercased(),
            sampleRate: parameters.sampleRate,
            channels: parameters.channels
        )
    }

    private func synthesizeXAI(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let url = normalizedBaseURL(service.trimmedBaseURL).appendingPathComponent("tts")
        let payload: [String: Any] = [
            "text": text,
            "voice_id": service.trimmedVoice,
            "language": service.languageType.isEmpty ? "auto" : service.languageType
        ]
        let data = try await fetchJSONAudio(
            url: url,
            apiKey: service.trimmedAPIKey,
            payload: payload
        )
        return AudioClip(data: data, format: "mp3", sampleRate: nil)
    }

    private func synthesizeElevenLabs(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let configuredBaseURL = normalizedBaseURL(service.trimmedBaseURL)
        var baseURL = URL(string: configuredBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
        if !baseURL.path.lowercased().hasSuffix("/v1") {
            baseURL.appendPathComponent("v1")
        }
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("text-to-speech")
                .appendingPathComponent(service.trimmedVoice),
            resolvingAgainstBaseURL: false
        )!
        let responseFormat = service.responseFormat.isEmpty ? "mp3_44100_128" : service.responseFormat
        components.queryItems = [URLQueryItem(name: "output_format", value: responseFormat)]
        var request = try jsonRequest(
            url: components.url!,
            payload: ["text": text, "model_id": service.trimmedModelID]
        )
        request.setValue(service.trimmedAPIKey, forHTTPHeaderField: "xi-api-key")
        let data = try await fetchData(for: request)
        if responseFormat.lowercased().hasPrefix("pcm_"),
           let sampleRate = Int(responseFormat.dropFirst(4)) {
            return AudioClip(data: data, format: "pcm", sampleRate: sampleRate)
        }
        let format = responseFormat.lowercased().hasPrefix("opus_") ? "opus" : "mp3"
        return AudioClip(data: data, format: format, sampleRate: nil)
    }

    private func synthesizeMiMo(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let parameters = service.advancedSettings
        let url = normalizedBaseURL(service.trimmedBaseURL)
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        let isVoiceDesign = service.trimmedModelID == "mimo-v2.5-tts-voicedesign"
        let isVoiceClone = service.trimmedModelID == "mimo-v2.5-tts-voiceclone"
        var messages: [[String: String]] = []
        if !parameters.instruction.isEmpty || isVoiceClone {
            messages.append(["role": "user", "content": parameters.instruction])
        }
        messages.append(["role": "assistant", "content": text])
        var audio: [String: Any] = ["format": "pcm16"]
        if isVoiceDesign {
            audio["optimize_text_preview"] = parameters.optimizeTextPreview
        } else {
            audio["voice"] = service.trimmedVoice
        }
        let payload: [String: Any] = [
            "model": service.trimmedModelID,
            "messages": messages,
            "audio": audio,
            "stream": true
        ]
        var request = try jsonRequest(url: url, payload: payload)
        request.setValue(service.trimmedAPIKey, forHTTPHeaderField: "api-key")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let data = try await fetchData(for: request)
        let output = await Task.detached(priority: .userInitiated) {
            var output = Data()
            for payload in Self.parseSSEPayloads(from: data) {
                guard let json = Self.jsonObject(from: payload),
                      let choices = json["choices"] as? [[String: Any]],
                      let choice = choices.first,
                      let container = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]),
                      let audio = container["audio"] as? [String: Any],
                      let base64 = audio["data"] as? String,
                      let chunk = Data(base64Encoded: base64) else { continue }
                output.append(chunk)
            }
            return output
        }.value
        guard !output.isEmpty else {
            throw ttsError(code: -8, message: NSLocalizedString("MiMo TTS 未返回可播放音频。", comment: ""))
        }
        return AudioClip(data: output, format: "pcm", sampleRate: 24_000)
    }

    private func synthesizeStepFun(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let parameters = service.advancedSettings
        let url = normalizedBaseURL(service.trimmedBaseURL).appendingPathComponent("audio/speech")
        var payload: [String: Any] = [
            "model": service.trimmedModelID,
            "input": text,
            "voice": service.trimmedVoice,
            "response_format": service.responseFormat,
            "speed": parameters.speed,
            "volume": parameters.volume,
            "sample_rate": parameters.sampleRate
        ]
        if service.trimmedModelID == "stepaudio-2.5-tts", !parameters.instruction.isEmpty {
            payload["instruction"] = parameters.instruction
        }
        let data = try await fetchJSONAudio(
            url: url,
            apiKey: service.trimmedAPIKey,
            payload: payload,
            accept: "application/octet-stream"
        )
        return AudioClip(
            data: data,
            format: service.responseFormat.lowercased(),
            sampleRate: parameters.sampleRate
        )
    }

    private func synthesizeFishAudio(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let parameters = service.advancedSettings
        let url = normalizedBaseURL(service.trimmedBaseURL)
            .appendingPathComponent("v1")
            .appendingPathComponent("tts")
        let payload: [String: Any] = [
            "text": text,
            "format": service.responseFormat,
            "temperature": parameters.temperature,
            "top_p": parameters.topP,
            "prosody": ["speed": parameters.speed],
            "sample_rate": parameters.sampleRate,
            "latency": parameters.latency,
            "reference_id": service.trimmedVoice
        ]
        var request = try jsonRequest(url: url, payload: payload)
        request.setValue("Bearer \(service.trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue(service.trimmedModelID, forHTTPHeaderField: "model")
        let data = try await fetchData(for: request)
        return AudioClip(
            data: data,
            format: service.responseFormat.lowercased(),
            sampleRate: parameters.sampleRate
        )
    }

    private func fetchJSONAudio(
        url: URL,
        apiKey: String,
        payload: [String: Any],
        accept: String? = nil
    ) async throws -> Data {
        var request = try jsonRequest(url: url, payload: payload)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        return try await fetchData(for: request)
    }

    private func jsonRequest(url: URL, payload: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = cloudRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private nonisolated static func jsonObject(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func ttsError(code: Int, message: String) -> NSError {
        NSError(domain: "TTS", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension Data {
    init?(ttsHexString: String) {
        let cleaned = ttsHexString.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

private extension String {
    var xmlTextEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    var xmlAttributeEscaped: String {
        xmlTextEscaped
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
