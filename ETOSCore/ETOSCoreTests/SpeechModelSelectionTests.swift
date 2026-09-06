import Testing
import Foundation
@testable import ETOSCore

@Suite("语音模型选择测试")
struct SpeechModelSelectionTests {

    @Test("语音模型列表默认包含系统语音识别模型")
    func testActivatedSpeechModelsContainsSystemModelByDefault() {
        let backupProviders = ConfigLoader.loadProviders()
        defer { restoreProviders(backupProviders) }

        clearAllProviders()

        let service = ChatService()
        let activated = service.activatedSpeechModels

        #expect(activated.count == 1)
        #expect(activated.first?.id == ChatService.systemSpeechRecognizerRunnableModel.id)
    }

    @Test("配置模型无需语音能力标记即可选择")
    func testActivatedSpeechModelsIncludesConfiguredModelsWithoutMarkers() {
        let backupProviders = ConfigLoader.loadProviders()
        defer { restoreProviders(backupProviders) }

        clearAllProviders()

        let chatModel = Model(
            modelName: "transcription-compatible-model",
            displayName: "语音识别服务",
            isActivated: false
        )
        let provider = Provider(
            name: "Speech Provider",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [chatModel]
        )
        ConfigLoader.saveProvider(provider)

        let activated = ChatService().activatedSpeechModels

        #expect(activated.count == 2)
        #expect(activated.first?.id == ChatService.systemSpeechRecognizerRunnableModel.id)
        #expect(activated.contains(where: { $0.model.modelName == "transcription-compatible-model" }))
    }

    @Test("语音模型列表不按普通模型用途过滤")
    func testActivatedSpeechModelsIncludesEveryConfiguredModelKind() {
        let backupProviders = ConfigLoader.loadProviders()
        defer { restoreProviders(backupProviders) }

        clearAllProviders()

        let chatModel = Model(
            modelName: "gpt-4o",
            displayName: "普通聊天",
            isActivated: true
        )
        let imageModel = Model(
            modelName: "gpt-image-1",
            displayName: "图片模型",
            kind: .image
        )
        let embeddingModel = Model(
            modelName: "text-embedding-3-small",
            displayName: "嵌入模型",
            kind: .embedding
        )
        let provider = Provider(
            name: "Speech Provider",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [chatModel, imageModel, embeddingModel]
        )
        ConfigLoader.saveProvider(provider)

        let service = ChatService()
        let activated = service.activatedSpeechModels

        #expect(activated.count == 4)
        #expect(activated.first?.id == ChatService.systemSpeechRecognizerRunnableModel.id)
        #expect(Set(activated.dropFirst().map(\.model.modelName)) == [
            "gpt-4o",
            "gpt-image-1",
            "text-embedding-3-small"
        ])
    }

    @Test("远端语音模型统一使用 OpenAI 转写适配器")
    func testRemoteTranscriptionAlwaysUsesOpenAICompatibleAdapter() async throws {
        let expectedURL = URL(string: "https://fake.url/audio/transcriptions")!
        let response = HTTPURLResponse(
            url: expectedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        MockURLProtocol.mockResponses = [
            expectedURL: .success((response, Data()))
        ]
        defer { MockURLProtocol.mockResponses = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let openAIAdapter = MockAPIAdapter()
        openAIAdapter.transcriptionRequestURL = expectedURL
        openAIAdapter.transcriptionResponseToReturn = "识别结果"
        let providerAdapter = MockAPIAdapter()
        let service = ChatService(
            adapters: [
                "openai-compatible": openAIAdapter,
                "gemini": providerAdapter
            ],
            urlSession: URLSession(configuration: configuration)
        )
        let provider = Provider(
            name: "兼容服务",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "gemini"
        )
        let model = RunnableModel(
            provider: provider,
            model: Model(modelName: "custom-transcriber")
        )

        let transcript = try await service.transcribeAudio(
            using: model,
            audioData: Data([1, 2, 3]),
            fileName: "recording.m4a",
            mimeType: "audio/m4a"
        )

        #expect(transcript == "识别结果")
        #expect(openAIAdapter.receivedTranscriptionModel?.id == model.id)
        #expect(providerAdapter.receivedTranscriptionModel == nil)
    }

#if canImport(Speech) && canImport(AVFoundation)
    @Test("系统语音识别将简体中文回退到可用地区")
    func testSystemSpeechLocaleResolverUsesSimplifiedChineseFallback() {
        let supportedLocales: Set<Locale> = [
            Locale(identifier: "en_US"),
            Locale(identifier: "zh_CN"),
            Locale(identifier: "zh_TW")
        ]

        let locale = SystemSpeechRecognizerService.resolvedSpeechRecognizerLocale(
            requestedIdentifier: nil,
            currentIdentifier: "zh-Hans-US",
            preferredIdentifiers: [],
            supportedLocales: supportedLocales
        )

        #expect(locale?.identifier == "zh_CN")
    }

    @Test("系统语音识别保留香港繁体中文地区")
    func testSystemSpeechLocaleResolverKeepsTraditionalHongKongRegion() {
        let supportedLocales: Set<Locale> = [
            Locale(identifier: "zh_CN"),
            Locale(identifier: "zh_HK"),
            Locale(identifier: "zh_TW")
        ]

        let locale = SystemSpeechRecognizerService.resolvedSpeechRecognizerLocale(
            requestedIdentifier: "zh-Hant-HK",
            currentIdentifier: "en-US",
            preferredIdentifiers: [],
            supportedLocales: supportedLocales
        )

        #expect(locale?.identifier == "zh_HK")
    }

    @Test("系统语音识别在当前地区不可用时使用首选语言")
    func testSystemSpeechLocaleResolverFallsBackToPreferredLanguage() {
        let supportedLocales: Set<Locale> = [
            Locale(identifier: "en_US"),
            Locale(identifier: "ja_JP")
        ]

        let locale = SystemSpeechRecognizerService.resolvedSpeechRecognizerLocale(
            requestedIdentifier: nil,
            currentIdentifier: "de-DE",
            preferredIdentifiers: ["ja-JP"],
            supportedLocales: supportedLocales
        )

        #expect(locale?.identifier == "ja_JP")
    }
#endif

    @Test("OCR 模型列表仅包含支持图像输入的聊天模型")
    func testActivatedOCRModelsIncludesVisionChatModelsOnly() {
        let backupProviders = ConfigLoader.loadProviders()
        defer { restoreProviders(backupProviders) }

        clearAllProviders()

        let visionChatModel = Model(
            modelName: "qwen-vl-max",
            displayName: "视觉聊天",
            isActivated: true,
            kind: .chat,
            inputModalities: [.text, .image]
        )
        let textChatModel = Model(
            modelName: "text-chat",
            displayName: "文本聊天",
            isActivated: true,
            kind: .chat
        )
        let imageGenerationModel = Model(
            modelName: "gpt-image-1",
            displayName: "生图",
            isActivated: true,
            kind: .image
        )
        let provider = Provider(
            name: "OCR Provider",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [visionChatModel, textChatModel, imageGenerationModel]
        )
        ConfigLoader.saveProvider(provider)

        let service = ChatService()
        let activated = service.activatedOCRModels

        #expect(activated.count == 1)
        #expect(activated.first?.model.modelName == "qwen-vl-max")
    }

    private func clearAllProviders() {
        let current = ConfigLoader.loadProviders()
        current.forEach { ConfigLoader.deleteProvider($0) }
    }

    private func restoreProviders(_ providers: [Provider]) {
        clearAllProviders()
        providers.forEach { ConfigLoader.saveProvider($0) }
    }
}
