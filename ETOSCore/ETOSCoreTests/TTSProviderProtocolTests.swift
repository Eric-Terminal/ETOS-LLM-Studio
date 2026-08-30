// ============================================================================
// TTSProviderProtocolTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证各家 TTS 的端点、认证方式与关键请求字段不会被误当成 OpenAI 兼容协议。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("TTS 供应商协议", .serialized)
@MainActor
struct TTSProviderProtocolTests {
    @Test("Azure 使用 SSML 与 Speech 专用请求头")
    func azureUsesSSMLProtocol() async throws {
        let manager = makeManager()
        var service = configuredService(.azure)
        service.baseURL = "https://eastus.tts.speech.microsoft.com/cognitiveservices/v1/"
        service.languageType = "zh-CN"
        service.voice = "zh-CN-XiaoxiaoNeural"

        _ = try await manager.synthesizeCloudAudio(
            text: "A&B",
            settings: TTSSettingsStore.shared.snapshot,
            service: service
        )

        let request = try #require(TTSProtocolURLProtocol.capturedRequest())
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(request.url?.path == "/cognitiveservices/v1")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/ssml+xml")
        #expect(request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat") == "audio-24khz-96kbitrate-mono-mp3")
        #expect(body.contains("xml:lang=\"zh-CN\""))
        #expect(body.contains("A&amp;B"))
    }

    @Test("ElevenLabs 将 Voice ID 放入路径并使用 xi-api-key")
    func elevenLabsUsesVoiceEndpoint() async throws {
        let manager = makeManager()
        var service = configuredService(.elevenLabs)
        service.baseURL = "https://api.elevenlabs.io/v1/"
        service.voice = "voice-123"

        _ = try await manager.synthesizeCloudAudio(
            text: "hello",
            settings: TTSSettingsStore.shared.snapshot,
            service: service
        )

        let request = try #require(TTSProtocolURLProtocol.capturedRequest())
        let payload = try requestJSON(request)
        #expect(request.url?.path == "/v1/text-to-speech/voice-123")
        #expect(request.url?.query == "output_format=mp3_44100_128")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "test-key")
        #expect(payload["model_id"] as? String == "eleven_multilingual_v2")
        #expect(payload["text"] as? String == "hello")
    }

    @Test("xAI 使用独立的语音字段")
    func xAIUsesDedicatedSpeechPayload() async throws {
        let manager = makeManager()
        var service = configuredService(.xAI)
        service.voice = "eve"
        service.languageType = "zh"

        _ = try await manager.synthesizeCloudAudio(
            text: "你好",
            settings: TTSSettingsStore.shared.snapshot,
            service: service
        )

        let request = try #require(TTSProtocolURLProtocol.capturedRequest())
        let payload = try requestJSON(request)
        #expect(request.url?.path == "/v1/tts")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(payload["voice_id"] as? String == "eve")
        #expect(payload["language"] as? String == "zh")
        #expect(payload["text"] as? String == "你好")
    }

    @Test("StepFun 发送语速音量采样率与语音指令")
    func stepFunUsesExtendedSpeechPayload() async throws {
        let manager = makeManager()
        var service = configuredService(.stepFun)
        service.advanced = TTSServiceAdvancedConfiguration(
            speed: 1.2,
            volume: 1.5,
            sampleRate: 24_000,
            instruction: "温柔地朗读"
        )

        _ = try await manager.synthesizeCloudAudio(
            text: "测试",
            settings: TTSSettingsStore.shared.snapshot,
            service: service
        )

        let request = try #require(TTSProtocolURLProtocol.capturedRequest())
        let payload = try requestJSON(request)
        #expect(request.url?.path == "/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(payload["speed"] as? Double == 1.2)
        #expect(payload["volume"] as? Double == 1.5)
        #expect(payload["sample_rate"] as? Int == 24_000)
        #expect(payload["instruction"] as? String == "温柔地朗读")
    }

    @Test("Fish Audio 使用模型请求头与参考音色参数")
    func fishAudioUsesModelHeaderAndReferenceID() async throws {
        let manager = makeManager()
        var service = configuredService(.fishAudio)
        service.voice = "reference-123"
        service.advanced = TTSServiceAdvancedConfiguration(
            speed: 1.1,
            sampleRate: 44_100,
            temperature: 0.6,
            topP: 0.8,
            latency: "balanced"
        )

        _ = try await manager.synthesizeCloudAudio(
            text: "测试",
            settings: TTSSettingsStore.shared.snapshot,
            service: service
        )

        let request = try #require(TTSProtocolURLProtocol.capturedRequest())
        let payload = try requestJSON(request)
        let prosody = try #require(payload["prosody"] as? [String: Any])
        #expect(request.url?.path == "/v1/tts")
        #expect(request.value(forHTTPHeaderField: "model") == "s2.1-pro")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(payload["reference_id"] as? String == "reference-123")
        #expect(payload["temperature"] as? Double == 0.6)
        #expect(payload["top_p"] as? Double == 0.8)
        #expect(prosody["speed"] as? Double == 1.1)
    }

    @Test("MiMo 使用 api-key 并解析 SSE PCM 音频")
    func miMoUsesSSEAudioProtocol() async throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        TTSProtocolURLProtocol.configureResponse(Data("""
        data: {"choices":[{"delta":{"audio":{"data":"\(pcm.base64EncodedString())"}}}]}

        data: [DONE]

        """.utf8))
        let manager = makeManager(resetResponse: false)
        let service = configuredService(.miMo)

        let clip = try await manager.synthesizeCloudAudio(
            text: "测试",
            settings: TTSSettingsStore.shared.snapshot,
            service: service
        )

        let request = try #require(TTSProtocolURLProtocol.capturedRequest())
        let payload = try requestJSON(request)
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "api-key") == "test-key")
        #expect(payload["stream"] as? Bool == true)
        #expect(clip.format == "pcm")
        #expect(clip.sampleRate == 24_000)
        #expect(clip.data == pcm)
    }

    private func makeManager(resetResponse: Bool = true) -> TTSManager {
        TTSProtocolURLProtocol.reset(resetResponse: resetResponse)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSProtocolURLProtocol.self]
        return TTSManager(urlSession: URLSession(configuration: configuration))
    }

    private func configuredService(_ kind: TTSProviderKind) -> TTSServiceConfiguration {
        var service = TTSServiceConfiguration.defaultConfiguration(for: kind)
        service.apiKey = "test-key"
        return service
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

private final class TTSProtocolURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var request: URLRequest?
    private static var responseBody = Data([0x01, 0x02, 0x03, 0x04])

    static func reset(resetResponse: Bool) {
        lock.lock()
        request = nil
        if resetResponse {
            responseBody = Data([0x01, 0x02, 0x03, 0x04])
        }
        lock.unlock()
    }

    static func configureResponse(_ data: Data) {
        lock.lock()
        responseBody = data
        lock.unlock()
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            // URLSession 交给 URLProtocol 时会把正文转成流，测试需要还原后才能验证协议字段。
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            capturedRequest.httpBodyStream = nil
            capturedRequest.httpBody = data
        }
        Self.lock.lock()
        Self.request = capturedRequest
        let body = Self.responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
