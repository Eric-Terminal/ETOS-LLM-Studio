// ============================================================================
// TTSManagerQwenAudioSynthesis.swift
// ============================================================================
// ETOS LLM Studio
//
// Qwen Audio 使用双向 WebSocket 生命周期，不能复用普通 HTTP TTS 请求。
// ============================================================================

import Foundation

extension TTSManager {
    func synthesizeQwenAudio(
        text: String,
        service: TTSServiceConfiguration
    ) async throws -> AudioClip {
        let parameters = service.advancedSettings
        let endpoint: String
        if parameters.workspaceID.isEmpty {
            endpoint = service.trimmedBaseURL
        } else {
            let region = parameters.region.isEmpty ? "cn-beijing" : parameters.region
            endpoint = "wss://\(parameters.workspaceID).\(region).maas.aliyuncs.com/api-ws/v1/inference"
        }
        guard let url = URL(string: endpoint), url.scheme?.lowercased().hasPrefix("ws") == true else {
            throw qwenAudioError(NSLocalizedString("Qwen Audio WebSocket 地址无效。", comment: ""))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = cloudRequestTimeoutSeconds
        request.setValue("Bearer \(service.trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        if !parameters.workspaceID.isEmpty {
            request.setValue(parameters.workspaceID, forHTTPHeaderField: "X-DashScope-WorkSpace")
        }

        let webSocket = urlSession.webSocketTask(with: request)
        webSocket.resume()
        defer { webSocket.cancel(with: .goingAway, reason: nil) }

        let taskID = UUID().uuidString.lowercased()
        try await webSocket.send(.string(try qwenAudioJSON([
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "tts",
                "function": "SpeechSynthesizer",
                "model": service.trimmedModelID,
                "parameters": [
                    "text_type": "PlainText",
                    "voice": service.trimmedVoice,
                    "format": service.responseFormat,
                    "sample_rate": parameters.sampleRate
                ],
                "input": [:] as [String: Any]
            ]
        ])))

        try await waitForQwenAudioStart(webSocket)
        try await webSocket.send(.string(try qwenAudioJSON([
            "header": [
                "action": "continue-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": ["text": text]]
        ])))
        try await webSocket.send(.string(try qwenAudioJSON([
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [:] as [String: Any]]
        ])))

        let audio = try await collectQwenAudio(webSocket)
        guard !audio.isEmpty else {
            throw qwenAudioError(NSLocalizedString("Qwen Audio TTS 未返回可播放音频。", comment: ""))
        }
        return AudioClip(
            data: audio,
            format: service.responseFormat.lowercased(),
            sampleRate: parameters.sampleRate
        )
    }

    private func waitForQwenAudioStart(_ webSocket: URLSessionWebSocketTask) async throws {
        while true {
            try Task.checkCancellation()
            let message = try await webSocket.receive()
            guard case .string(let string) = message else { continue }
            switch try qwenAudioLifecycle(from: string) {
            case .started:
                return
            case .failed(let message):
                throw qwenAudioError(message)
            case .finished:
                throw qwenAudioError(NSLocalizedString("Qwen Audio TTS 在开始前结束。", comment: ""))
            case .ignored:
                continue
            }
        }
    }

    private func collectQwenAudio(_ webSocket: URLSessionWebSocketTask) async throws -> Data {
        var audio = Data()
        while true {
            try Task.checkCancellation()
            switch try await webSocket.receive() {
            case .data(let data):
                audio.append(data)
            case .string(let string):
                switch try qwenAudioLifecycle(from: string) {
                case .finished:
                    return audio
                case .failed(let message):
                    throw qwenAudioError(message)
                case .started, .ignored:
                    continue
                }
            @unknown default:
                continue
            }
        }
    }

    private func qwenAudioLifecycle(from string: String) throws -> QwenAudioLifecycle {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any] else {
            throw qwenAudioError(NSLocalizedString("Qwen Audio TTS 返回了无效事件。", comment: ""))
        }
        let event = header["event"] as? String ?? ""
        switch event {
        case "task-started":
            return .started
        case "task-finished":
            return .finished
        case "task-failed", "error":
            let payload = json["payload"] as? [String: Any]
            let detail = header["error_message"] ?? header["error_code"] ?? payload?["message"]
            let message = detail.map { String(describing: $0) }
                ?? NSLocalizedString("Qwen Audio TTS 请求失败。", comment: "")
            return .failed(message)
        default:
            return .ignored
        }
    }

    private func qwenAudioJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw qwenAudioError(NSLocalizedString("Qwen Audio TTS 请求编码失败。", comment: ""))
        }
        return string
    }

    private func qwenAudioError(_ message: String) -> NSError {
        NSError(domain: "TTS.QwenAudio", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum QwenAudioLifecycle {
    case started
    case finished
    case failed(String)
    case ignored
}
