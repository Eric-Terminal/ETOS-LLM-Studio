import Testing
import Foundation
import Combine
@testable import Shared

@Suite("TTS 模型选择测试")
struct TTSModelSelectionTests {

    @Test("模型能力支持 textToSpeech")
    func testModelSupportsTextToSpeechCapability() {
        let model = Model(modelName: "gpt-4o-mini-tts", kind: .textToSpeech)
        #expect(model.supportsTextToSpeech)
    }

    @Test("存在 TTS 能力模型时优先返回可 TTS 模型")
    func testActivatedTTSModelsPrefersCapableModels() {
        let backupProviders = ConfigLoader.loadProviders()
        let backupTTSIdentifier = Persistence.readAppConfigText(key: AppConfigKey.ttsModelIdentifier.rawValue)
        defer {
            restoreProviders(backupProviders)
            if let backupTTSIdentifier {
                Persistence.writeAppConfig(key: AppConfigKey.ttsModelIdentifier.rawValue, text: backupTTSIdentifier)
            } else {
                Persistence.deleteAppConfig(key: AppConfigKey.ttsModelIdentifier.rawValue)
            }
        }

        clearAllProviders()

        let ttsModel = Model(modelName: "gpt-4o-mini-tts", displayName: "TTS", isActivated: true, kind: .textToSpeech)
        let normalModel = Model(modelName: "gpt-4o", displayName: "Chat", isActivated: true)
        let provider = Provider(
            name: "TTS Provider",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [ttsModel, normalModel]
        )
        ConfigLoader.saveProvider(provider)

        let service = ChatService()
        let activated = service.activatedTTSModels

        #expect(activated.count == 1)
        #expect(activated.first?.model.modelName == "gpt-4o-mini-tts")

        if let chosen = activated.first {
            Persistence.writeAppConfig(key: AppConfigKey.ttsModelIdentifier.rawValue, text: chosen.id)
            let resolved = service.resolveSelectedTTSModel()
            #expect(resolved?.id == chosen.id)
        } else {
            Issue.record("未解析到 TTS 模型")
        }
    }

    @Test("没有 TTS 能力模型时列表为空")
    func testActivatedTTSModelsEmptyWhenNoCapableModel() {
        let backupProviders = ConfigLoader.loadProviders()
        defer { restoreProviders(backupProviders) }

        clearAllProviders()

        let chatModel = Model(modelName: "gpt-4o", displayName: "Chat", isActivated: true)
        let provider = Provider(
            name: "Chat Provider",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [chatModel]
        )
        ConfigLoader.saveProvider(provider)

        let service = ChatService()
        let activated = service.activatedTTSModels

        #expect(activated.isEmpty)
        #expect(service.resolveSelectedTTSModel() == nil)
    }

    @Test("对话模型列表会排除嵌入等专用用途模型")
    func testActivatedConversationModelsExcludesEmbeddingModels() {
        let backupProviders = ConfigLoader.loadProviders()
        let backupSelectedModelID = Persistence.readAppConfigText(key: AppConfigKey.selectedRunnableModelID.rawValue)
        defer {
            restoreProviders(backupProviders)
            if let backupSelectedModelID {
                Persistence.writeAppConfig(
                    key: AppConfigKey.selectedRunnableModelID.rawValue,
                    text: backupSelectedModelID,
                    typeHint: AppConfigKey.selectedRunnableModelID.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: AppConfigKey.selectedRunnableModelID.rawValue)
            }
        }

        clearAllProviders()

        let chatModel = Model(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            modelName: "chat-model",
            displayName: "聊天模型",
            isActivated: true,
            kind: .chat
        )
        let embeddingModel = Model(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            modelName: "embedding-model",
            displayName: "嵌入模型",
            isActivated: true,
            kind: .embedding
        )
        let imageModel = Model(
            id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            modelName: "image-model",
            displayName: "生图模型",
            isActivated: true,
            kind: .image
        )
        let provider = Provider(
            id: UUID(uuidString: "44444444-5555-6666-7777-888888888888")!,
            name: "用途过滤提供商",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [embeddingModel, imageModel, chatModel]
        )
        ConfigLoader.saveProvider(provider)
        let embeddingRunnable = RunnableModel(provider: provider, model: embeddingModel)
        Persistence.writeAppConfig(
            key: AppConfigKey.selectedRunnableModelID.rawValue,
            text: embeddingRunnable.id,
            typeHint: AppConfigKey.selectedRunnableModelID.typeHint
        )

        let service = ChatService()

        #expect(service.activatedRunnableModels.contains(where: { $0.id == embeddingRunnable.id }))
        #expect(!service.activatedConversationModels.contains(where: { $0.id == embeddingRunnable.id }))
        #expect(service.activatedConversationModels.contains(where: { $0.model.kind == .image }))
        #expect(service.activatedConversationModels.contains(where: { $0.model.kind == .chat }))
        #expect(service.activatedChatModels.map(\.model.kind) == [.chat])
        #expect(service.selectedModelSubject.value?.model.isConversationModel == true)

        let selectedBeforeEmbeddingAttempt = service.selectedModelSubject.value?.id
        service.setSelectedModel(embeddingRunnable)
        #expect(service.selectedModelSubject.value?.id == selectedBeforeEmbeddingAttempt)
    }

    @Test("删除当前选中提供商后会切换到可用模型")
    func testDeletingSelectedProviderReconcilesSelectedModel() {
        let backupProviders = ConfigLoader.loadProviders()
        let backupSelectedModelID = Persistence.readAppConfigText(key: AppConfigKey.selectedRunnableModelID.rawValue)
        defer {
            restoreProviders(backupProviders)
            if let backupSelectedModelID {
                Persistence.writeAppConfig(
                    key: AppConfigKey.selectedRunnableModelID.rawValue,
                    text: backupSelectedModelID,
                    typeHint: AppConfigKey.selectedRunnableModelID.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: AppConfigKey.selectedRunnableModelID.rawValue)
            }
        }

        clearAllProviders()

        let deletedModel = Model(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            modelName: "deleted-model",
            displayName: "待删除模型",
            isActivated: true
        )
        let fallbackModel = Model(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            modelName: "fallback-model",
            displayName: "备用模型",
            isActivated: true
        )
        let deletedProvider = Provider(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "待删除提供商",
            baseURL: "https://deleted.example.com/v1",
            apiKeys: ["deleted-key"],
            apiFormat: "openai-compatible",
            models: [deletedModel]
        )
        let fallbackProvider = Provider(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "备用提供商",
            baseURL: "https://fallback.example.com/v1",
            apiKeys: ["fallback-key"],
            apiFormat: "openai-compatible",
            models: [fallbackModel]
        )
        ConfigLoader.saveProvider(deletedProvider)
        ConfigLoader.saveProvider(fallbackProvider)

        let service = ChatService()
        let deletedRunnable = RunnableModel(provider: deletedProvider, model: deletedModel)
        let fallbackRunnable = RunnableModel(provider: fallbackProvider, model: fallbackModel)
        service.setSelectedModel(deletedRunnable)

        service.deleteProvider(deletedProvider)

        #expect(!service.providersSubject.value.contains(where: { $0.id == deletedProvider.id }))
        #expect(!service.configuredRunnableModels.contains(where: { $0.id == deletedRunnable.id }))
        #expect(service.selectedModelSubject.value?.id == fallbackRunnable.id)
        #expect(Persistence.readAppConfigText(key: AppConfigKey.selectedRunnableModelID.rawValue) == fallbackRunnable.id)
    }

    @Test("文本分片函数会按标点与长度切分")
    func testSplitTextForPlayback() {
        let text = "你好世界。今天继续测试分片能力！最后一句"
        let chunks = TTSManager.splitTextForPlayback(text, maxLength: 6)

        #expect(chunks == ["你好世界。", "今天继续测试", "分片能力！", "最后一句"])
    }

    @Test("提取引号内容时保留嵌套单引号词")
    func testExtractQuotedContentKeepsNestedSingleQuotedWords() {
        let text = "提示：“请朗读 'Alpha' 和 'Beta'，不要漏掉后半句。”"
        let quoted = TTSManager.extractQuotedContentForPlayback(text)

        #expect(quoted == "请朗读 'Alpha' 和 'Beta'，不要漏掉后半句。")
    }

    @Test("提取多个引号片段时按原顺序拼接")
    func testExtractQuotedContentKeepsMultipleSegments() {
        let text = "她说“第一句”，又说“第二句”。"
        let quoted = TTSManager.extractQuotedContentForPlayback(text)

        #expect(quoted == "第一句\n第二句")
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
