import Testing
import Foundation
@testable import Shared

@Suite("语音模型选择测试")
struct SpeechModelSelectionTests {

    @Test("模型能力支持 speechToText")
    func testModelSupportsSpeechToTextCapability() {
        let model = Model(modelName: "gpt-4o-transcribe", capabilities: [.speechToText])
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
            capabilities: [.speechToText]
        )
        let chatModel = Model(
            modelName: "gpt-4o",
            displayName: "普通聊天",
            isActivated: true,
            capabilities: [.chat]
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

    private func clearAllProviders() {
        let current = ConfigLoader.loadProviders()
        current.forEach { ConfigLoader.deleteProvider($0) }
    }

    private func restoreProviders(_ providers: [Provider]) {
        clearAllProviders()
        providers.forEach { ConfigLoader.saveProvider($0) }
    }
}
