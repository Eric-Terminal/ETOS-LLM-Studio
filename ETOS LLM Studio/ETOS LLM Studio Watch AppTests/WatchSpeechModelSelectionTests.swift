import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("手表语音模型选择", .serialized)
struct WatchSpeechModelSelectionTests {
    @Test("手表目录不提供无法调用的系统语音模型")
    func excludesSystemSpeechRecognizer() {
        let service = ChatService(adapters: [:])
        #expect(!service.activatedSpeechModels.contains { ChatService.isSystemSpeechRecognizerModel($0) })
    }

    @Test("旧系统模型或失效选择在目录就绪后改用首项并保存", arguments: [true, false])
    func invalidSelectionUsesFirstModel(wasSystemModel: Bool) async {
        let config = AppConfigStore.shared
        let previousIdentifier = config.speechModelIdentifier
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        let provider = Provider(name: "转写服务", baseURL: "https://example.com/v1", apiKeys: [], apiFormat: "openai-compatible")
        let first = RunnableModel(provider: provider, model: Model(modelName: "first-transcriber"))
        let second = RunnableModel(provider: provider, model: Model(modelName: "second-transcriber"))
        let oldIdentifier = wasSystemModel ? ChatService.systemSpeechRecognizerRunnableModel.id : "removed-transcriber"
        viewModel.speechModelIdentifier = oldIdentifier
        viewModel.selectedSpeechModel = ChatService.systemSpeechRecognizerRunnableModel
        viewModel.speechModels = []

        // 初始目录尚未发布时，不丢失待替换的已存 ID，也不保留不可用的 UI 选择。
        viewModel.syncSpeechModelSelection()
        #expect(viewModel.selectedSpeechModel == nil)
        #expect(viewModel.speechModelIdentifier == oldIdentifier)

        viewModel.speechModels = [first, second]
        viewModel.syncSpeechModelSelection()
        #expect(viewModel.selectedSpeechModel?.id == first.id)
        #expect(viewModel.speechModelIdentifier == first.id)
        #expect(Persistence.readAppConfigText(key: AppConfigKey.speechModelIdentifier.rawValue) == first.id)

        config.speechModelIdentifier = previousIdentifier
        await config.flushPendingWrites()
    }

    @Test("有效选择与主动未选择不被首项覆盖", arguments: [true, false])
    func preservesCurrentChoice(hasSelection: Bool) async {
        let config = AppConfigStore.shared
        let previousIdentifier = config.speechModelIdentifier
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        let provider = Provider(name: "转写服务", baseURL: "https://example.com/v1", apiKeys: [], apiFormat: "openai-compatible")
        let first = RunnableModel(provider: provider, model: Model(modelName: "first-transcriber"))
        let second = RunnableModel(provider: provider, model: Model(modelName: "second-transcriber"))
        viewModel.speechModels = [first, second]
        viewModel.speechModelIdentifier = hasSelection ? second.id : ""

        viewModel.syncSpeechModelSelection()
        #expect(viewModel.selectedSpeechModel?.id == (hasSelection ? second.id : nil))
        #expect(viewModel.speechModelIdentifier == (hasSelection ? second.id : ""))

        config.speechModelIdentifier = previousIdentifier
        await config.flushPendingWrites()
    }
}
