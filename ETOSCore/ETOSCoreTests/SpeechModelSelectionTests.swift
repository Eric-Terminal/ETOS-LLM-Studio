import Testing
import Foundation
@testable import ETOSCore

@Suite("语音模型选择测试")
struct SpeechModelSelectionTests {

    @Test("模型能力支持 speechToText")
    func testModelSupportsSpeechToTextCapability() {
        let model = Model(modelName: "gpt-4o-transcribe", kind: .speechToText)
        #expect(model.supportsSpeechToText)
    }

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

    @Test("存在可用语音模型时保留系统语音识别并包含远端语音模型")
    func testActivatedSpeechModelsIncludesSystemAndRemoteSpeechModels() {
        let backupProviders = ConfigLoader.loadProviders()
        defer { restoreProviders(backupProviders) }

        clearAllProviders()

        let speechModel = Model(
            modelName: "gpt-4o-transcribe",
            displayName: "云端语音",
            isActivated: true,
            kind: .speechToText
        )
        let chatModel = Model(
            modelName: "gpt-4o",
            displayName: "普通聊天",
            isActivated: true
        )
        let provider = Provider(
            name: "Speech Provider",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [speechModel, chatModel]
        )
        ConfigLoader.saveProvider(provider)

        let service = ChatService()
        let activated = service.activatedSpeechModels

        #expect(activated.count == 2)
        #expect(activated.first?.id == ChatService.systemSpeechRecognizerRunnableModel.id)
        #expect(activated.contains(where: { $0.model.modelName == "gpt-4o-transcribe" }))
        #expect(!activated.contains(where: { $0.model.modelName == "gpt-4o" }))
    }

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
