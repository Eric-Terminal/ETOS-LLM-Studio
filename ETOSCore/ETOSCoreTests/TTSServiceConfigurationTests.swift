import Testing
import Foundation
import Combine
@testable import ETOSCore

@Suite("TTS 服务测试")
struct TTSServiceConfigurationTests {

    @Test("旧模型配置中的 TTS 能力仍可读取")
    func testLegacyModelSupportsTextToSpeechCapability() {
        let model = Model(modelName: "gpt-4o-mini-tts", kind: .textToSpeech)
        #expect(model.supportsTextToSpeech)
    }

    @Test("独立服务提供可直接使用的协议默认值")
    func testDefaultServiceConfiguration() {
        let service = TTSServiceConfiguration.defaultConfiguration(for: .openAICompatible)

        #expect(service.baseURL == "https://api.openai.com/v1")
        #expect(service.modelID == "gpt-4o-mini-tts")
        #expect(service.voice == "alloy")
        #expect(!service.isReady)
    }

    @Test("所有网络语音协议都有独立的推荐配置")
    func testAllProviderKindsHaveRecommendedConfiguration() {
        let services = TTSProviderKind.allCases.map {
            TTSServiceConfiguration.defaultConfiguration(for: $0)
        }

        #expect(services.count == 12)
        #expect(Set(services.map(\.providerKind)) == Set(TTSProviderKind.allCases))
        #expect(services.allSatisfy { !$0.name.isEmpty })
        #expect(services.allSatisfy { !$0.voice.isEmpty || $0.providerKind == .elevenLabs || $0.providerKind == .fishAudio })
        #expect(services.allSatisfy { $0.advanced != nil })
        #expect(services.first(where: { $0.providerKind == .gemini })?.modelID == "gemini-3.1-flash-tts-preview")
        #expect(services.first(where: { $0.providerKind == .miniMax })?.modelID == "speech-2.8-turbo")
        #expect(services.first(where: { $0.providerKind == .qwenAudio })?.baseURL.hasPrefix("wss://") == true)
    }

    @Test("供应商字段描述只暴露对应协议支持的参数")
    func testProviderConfigurationFields() {
        let azureFields = TTSProviderPresetCatalog.configurationFields(for: .azure)
        let miniMaxFields = TTSProviderPresetCatalog.configurationFields(for: .miniMax)
        let fishAudioFields = TTSProviderPresetCatalog.configurationFields(for: .fishAudio)

        #expect(azureFields == [.language])
        #expect(miniMaxFields.contains(.pronunciationDictionary))
        #expect(miniMaxFields.contains(.subtitles))
        #expect(fishAudioFields.contains(.temperature))
        #expect(fishAudioFields.contains(.topP))
        #expect(!TTSProviderPresetCatalog.requiresModelID(for: .xAI))
        #expect(TTSProviderPresetCatalog.requiresModelID(for: .elevenLabs))
    }

    @Test("旧服务配置缺少高级参数时仍可解码并补上推荐值")
    func testDecodingLegacyServiceWithoutAdvancedConfiguration() throws {
        let data = Data("""
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "旧服务",
          "providerKind": "openai-compatible",
          "baseURL": "https://example.com/v1",
          "apiKey": "secret",
          "modelID": "tts-model",
          "voice": "voice",
          "responseFormat": "mp3",
          "languageType": "Auto",
          "miniMaxEmotion": "calm"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(TTSServiceConfiguration.self, from: data)

        #expect(decoded.advanced == nil)
        #expect(decoded.normalized.advanced == TTSProviderPresetCatalog.recommendedPreset(for: .openAICompatible).advanced)
        #expect(decoded.normalized.isReady)
    }

    @Test("独立服务完整配置后可以播放")
    func testConfiguredServiceIsReady() {
        var service = TTSServiceConfiguration.defaultConfiguration(for: .qwen)
        service.apiKey = "  secret  "

        let normalized = service.normalized

        #expect(normalized.apiKey == "secret")
        #expect(normalized.isReady)
        #expect(normalized.modelID == "qwen3-tts-flash")
        #expect(normalized.languageType == "Auto")
    }

    @Test("服务地址必须符合当前协议")
    func testServiceEndpointSchemeValidation() {
        var httpService = TTSServiceConfiguration.defaultConfiguration(for: .openAICompatible)
        httpService.apiKey = "secret"
        httpService.baseURL = "wss://example.com/v1"

        var webSocketService = TTSServiceConfiguration.defaultConfiguration(for: .qwenAudio)
        webSocketService.apiKey = "secret"
        webSocketService.baseURL = "https://example.com/api-ws/v1/inference"

        #expect(!httpService.isReady)
        #expect(!webSocketService.isReady)

        httpService.baseURL = "https://example.com/v1"
        webSocketService.baseURL = "wss://example.com/api-ws/v1/inference"
        #expect(httpService.isReady)
        #expect(webSocketService.isReady)
    }

    @Test("切换接口类型会保留服务身份并换用对应默认值")
    func testChangingProviderKindPreservesIdentity() {
        let service = TTSServiceConfiguration.defaultConfiguration(for: .openAICompatible)
        let changed = service.changingProviderKind(to: .gemini)

        #expect(changed.id == service.id)
        #expect(changed.providerKind == .gemini)
        #expect(changed.baseURL == "https://generativelanguage.googleapis.com/v1beta")
        #expect(changed.modelID == "gemini-3.1-flash-tts-preview")
    }

    @Test("旧通用模型配置可迁移为独立 TTS 服务")
    func testMigratingLegacyModelToService() {
        let model = Model(modelName: "legacy-tts", displayName: "旧语音", isActivated: true, kind: .textToSpeech)
        let provider = Provider(
            name: "旧提供商",
            baseURL: "https://legacy.example/v1",
            apiKeys: ["legacy-key"],
            apiFormat: "openai-compatible",
            models: [model]
        )
        let settings = TTSSettingsSnapshot(
            playbackMode: .cloud,
            providerKind: .openAICompatible,
            autoPlayAfterAssistantResponse: false,
            onlyReadQuotedContent: false,
            watchUseLightweightPreprocess: true,
            watchSpeechMaxCharacters: 2_000,
            speechRate: 1,
            pitch: 1,
            playbackSpeed: 1,
            voice: "nova",
            responseFormat: "mp3",
            languageType: "Auto",
            miniMaxEmotion: "calm"
        )

        let migrated = TTSServiceConfiguration.migrated(
            from: RunnableModel(provider: provider, model: model),
            settings: settings
        )

        #expect(migrated.name == "旧语音")
        #expect(migrated.baseURL == provider.baseURL)
        #expect(migrated.apiKey == "legacy-key")
        #expect(migrated.modelID == "legacy-tts")
        #expect(migrated.voice == "nova")
        #expect(migrated.isReady)
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

    @Test("朗读内容模式会排除中英文括号内容")
    func testTextSelectionExcludesParentheses() {
        let selected = TTSManager.selectTextForPlayback(
            "开头（舞台动作）中间 (aside) 结尾",
            mode: .outsideParentheses
        )

        #expect(selected == "开头 中间 结尾")
    }

    @Test("朗读内容模式可以只保留 Markdown 斜体")
    func testTextSelectionKeepsItalicContent() {
        let selected = TTSManager.selectTextForPlayback(
            "普通 *第一段* 文字与 _第二段_。",
            mode: .italicOnly
        )

        #expect(selected == "第一段\n第二段")
    }

    @Test("朗读内容模式可以移除 Markdown 斜体")
    func testTextSelectionRemovesItalicContent() {
        let selected = TTSManager.selectTextForPlayback(
            "保留 *移除* 结尾",
            mode: .nonItalic
        )

        #expect(selected == "保留 结尾")
    }

    @Test("下划线标识符不会被误判为斜体")
    func testTextSelectionIgnoresIdentifierUnderscores() {
        let selected = TTSManager.selectTextForPlayback(
            "保留 foo_bar_baz",
            mode: .italicOnly
        )

        #expect(selected == "保留 foo_bar_baz")
    }

    @Test("朗读内容模式会识别 HTML 斜体标签")
    func testTextSelectionKeepsHTMLItalicContent() {
        let selected = TTSManager.selectTextForPlayback(
            "普通 <em>第一段</em> 与 <i class=\"voice\">第二段</i>",
            mode: .italicOnly
        )

        #expect(selected == "第一段\n第二段")
    }

    @Test("PCM 网络分片会合并为可导出的 WAV")
    func testPCMClipsBuildWAVExport() throws {
        let export = try #require(TTSAudioExportBuilder.make(from: [
            TTSManager.AudioClip(data: Data([0x01, 0x02]), format: "pcm", sampleRate: 24_000),
            TTSManager.AudioClip(data: Data([0x03, 0x04]), format: "pcm", sampleRate: 24_000)
        ]))

        #expect(export.fileExtension == "wav")
        #expect(String(data: Data(export.data.prefix(4)), encoding: .ascii) == "RIFF")
        #expect(Data(export.data.suffix(4)) == Data([0x01, 0x02, 0x03, 0x04]))
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
