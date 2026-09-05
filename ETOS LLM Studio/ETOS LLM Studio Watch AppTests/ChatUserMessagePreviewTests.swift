import Foundation
import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("watchOS 长用户消息预览", .serialized)
struct ChatUserMessagePreviewTests {
    @Test("修改字符数会刷新缓存预览，放宽后多行文本可完整显示")
    func refreshesCachedPreviewWhenLimitChanges() async {
        let appConfig = AppConfigStore.shared
        let previousLimit = appConfig.userMessagePreviewCharacterLimit
        defer { appConfig.userMessagePreviewCharacterLimit = previousLimit }
        appConfig.userMessagePreviewCharacterLimit = 20
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        viewModel.observeUserMessagePreviewCharacterLimit()
        let message = ChatMessage(role: .user, content: String(repeating: "行\n", count: 50))
        let state = ChatMessageRenderState(message: message, defersUserContentPreparation: true)
        viewModel.messageStateByID[message.id] = state
        viewModel.scheduleVisualMessagePreparationIfNeeded(for: state, source: message)
        await viewModel.visualMessagePrepareTasks[message.id]?.value
        #expect(state.visualMessage.content == String(message.content.prefix(20)) + "…")

        for limit in [120, 12] {
            appConfig.userMessagePreviewCharacterLimit = limit
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            await viewModel.visualMessagePrepareTasks[message.id]?.value
            let expected = ChatUserMessagePreview(content: message.content, characterLimit: limit)
            #expect(state.visualMessage.content == expected.content)
            #expect(state.isUserContentTruncated == expected.isTruncated)
            #expect(state.message == message)
        }
    }

    @Test("后台截断不改写原文、不准备全文 Markdown，编辑后恢复正常渲染")
    func preparesPreviewAndRefreshesAfterEditing() async throws {
        let appConfig = AppConfigStore.shared
        let previousLimit = appConfig.userMessagePreviewCharacterLimit
        defer { appConfig.userMessagePreviewCharacterLimit = previousLimit }
        appConfig.userMessagePreviewCharacterLimit = ChatUserMessagePreview.defaultCharacterLimit
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        let message = ChatMessage(role: .user, content: String(repeating: "**长输入**", count: 2_000))
        let state = ChatMessageRenderState(message: message, defersUserContentPreparation: true)
        viewModel.messageStateByID[message.id] = state

        viewModel.scheduleVisualMessagePreparationIfNeeded(for: state, source: message)
        let preparation = try #require(viewModel.visualMessagePrepareTasks[message.id])
        await preparation.value

        #expect(ChatUserMessagePreview.defaultCharacterLimit == 300)
        #expect(state.isUserContentTruncated)
        #expect(state.visualMessage.content == ChatUserMessagePreview(content: message.content).content)
        #expect(state.message == message)
        #expect(viewModel.preparedMarkdownByMessageID[message.id] == nil)
        #expect(viewModel.markdownPrepareTasks[message.id] == nil)
        #expect(state.roleplayHTML == nil)

        // 在旧预览完成前编辑消息，旧任务不得覆盖最新正文或恢复截断标记。
        viewModel.scheduleVisualMessagePreparationIfNeeded(for: state, source: message)
        let stalePreparation = try #require(viewModel.visualMessagePrepareTasks[message.id])
        var editedMessage = message
        editedMessage.content = "**短输入**"
        state.update(with: editedMessage)
        viewModel.scheduleVisualMessagePreparationIfNeeded(for: state, source: editedMessage)
        let editedPreparation = try #require(viewModel.visualMessagePrepareTasks[message.id])
        await stalePreparation.value
        await editedPreparation.value
        if let markdownPreparation = viewModel.markdownPrepareTasks[message.id] {
            await markdownPreparation.value
        }

        #expect(!state.isUserContentTruncated)
        #expect(state.message == editedMessage)
        #expect(state.visualMessage.content == editedMessage.content)
        #expect(viewModel.preparedMarkdownByMessageID[message.id]?.sourceText == editedMessage.content)
    }
}
