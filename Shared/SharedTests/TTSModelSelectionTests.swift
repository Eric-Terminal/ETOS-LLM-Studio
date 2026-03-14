import Testing
import Foundation
@testable import Shared

@Suite("TTS 模型选择测试")
struct TTSModelSelectionTests {

    @Test("模型能力支持 textToSpeech")
    func testModelSupportsTextToSpeechCapability() {
        let model = Model(modelName: "gpt-4o-mini-tts", capabilities: [.chat, .textToSpeech])
        #expect(model.supportsTextToSpeech)
    }

    @Test("存在 TTS 能力模型时优先返回可 TTS 模型")
    func testActivatedTTSModelsPrefersCapableModels() {
        let backupProviders = ConfigLoader.loadProviders()
        let backupTTSIdentifier = UserDefaults.standard.string(forKey: "ttsModelIdentifier")
        defer {
            restoreProviders(backupProviders)
            if let backupTTSIdentifier {
                UserDefaults.standard.set(backupTTSIdentifier, forKey: "ttsModelIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "ttsModelIdentifier")
            }
        }

        clearAllProviders()

        let ttsModel = Model(modelName: "gpt-4o-mini-tts", displayName: "TTS", isActivated: true, capabilities: [.chat, .textToSpeech])
        let normalModel = Model(modelName: "gpt-4o", displayName: "Chat", isActivated: true, capabilities: [.chat])
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
            UserDefaults.standard.set(chosen.id, forKey: "ttsModelIdentifier")
            let resolved = service.resolveSelectedTTSModel()
            #expect(resolved?.id == chosen.id)
        } else {
            Issue.record("未解析到 TTS 模型")
        }
    }

    @Test("没有 TTS 能力模型时回退到全部激活模型")
    func testActivatedTTSModelsFallsBackToActivatedModels() {
        let backupProviders = ConfigLoader.loadProviders()
        defer { restoreProviders(backupProviders) }

        clearAllProviders()

        let chatModel = Model(modelName: "gpt-4o", displayName: "Chat", isActivated: true, capabilities: [.chat])
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

        #expect(activated.count == 1)
        #expect(activated.first?.model.modelName == "gpt-4o")
    }

    @Test("文本分片函数会按标点与长度切分")
    func testSplitTextForPlayback() {
        let text = "你好世界。今天继续测试分片能力！最后一句"
        let chunks = TTSManager.splitTextForPlayback(text, maxLength: 6)

        #expect(chunks == ["你好世界。", "今天继续测试", "分片能力！", "最后一句"])
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
