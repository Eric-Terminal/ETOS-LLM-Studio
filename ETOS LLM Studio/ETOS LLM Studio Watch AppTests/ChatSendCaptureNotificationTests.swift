import Combine
import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("watchOS 发送捕获通知", .serialized)
struct ChatSendCaptureNotificationTests {
    @Test("发送只发布实际消费的附件，撤销仍完整恢复草稿", arguments: [false, true])
    func attachmentNotificationsRequireConsumedContent(hasAttachments: Bool) async {
        let config = AppConfigStore.shared
        let previousDelay = config.chatSendDelaySeconds
        let previousDraft = config.chatComposerDraft
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        viewModel.isSendingMessage = false
        let draft = hasAttachments ? "" : "纯文本发送通知回归"
        let audio = AudioAttachment(data: Data([1]), mimeType: "audio/wav", format: "wav", fileName: "capture.wav")
        let image = ImageAttachment(data: Data([2]), mimeType: "image/png", fileName: "capture.png")
        let file = FileAttachment(data: Data([3]), mimeType: "text/plain", fileName: "capture.txt")
        viewModel.userInput = draft
        if hasAttachments {
            viewModel.pendingAudioAttachment = audio
            viewModel.pendingImageAttachments = [image]
            viewModel.pendingFileAttachments = [file]
        }
        // 延迟任务在首个 await 前撤销，既走真实捕获入口，也不会提交 Core 请求。
        config.chatSendDelaySeconds = 10
        var audioChanges = 0, imageChanges = 0, fileChanges = 0
        let subscriptions = [
            viewModel.$pendingAudioAttachment.dropFirst().sink { _ in audioChanges += 1 },
            viewModel.$pendingImageAttachments.dropFirst().sink { _ in imageChanges += 1 },
            viewModel.$pendingFileAttachments.dropFirst().sink { _ in fileChanges += 1 }
        ]
        viewModel.sendMessage()
        let delayedTask = viewModel.pendingSendDelayTask
        #expect(delayedTask != nil && viewModel.isSendDelayPending)
        #expect(viewModel.userInput.isEmpty)
        #expect(viewModel.pendingAudioAttachment == nil)
        #expect(viewModel.pendingImageAttachments.isEmpty && viewModel.pendingFileAttachments.isEmpty)
        #expect(audioChanges == (hasAttachments ? 1 : 0))
        #expect(imageChanges == (hasAttachments ? 1 : 0))
        #expect(fileChanges == (hasAttachments ? 1 : 0))
        subscriptions.forEach { $0.cancel() }

        viewModel.cancelSending()
        #expect(!viewModel.isSendDelayPending && viewModel.pendingSendDelayTask == nil)
        #expect(viewModel.userInput == draft)
        #expect(viewModel.pendingAudioAttachment?.id == (hasAttachments ? audio.id : nil))
        #expect(viewModel.pendingImageAttachments.map(\.id) == (hasAttachments ? [image.id] : []))
        #expect(viewModel.pendingFileAttachments.map(\.id) == (hasAttachments ? [file.id] : []))
        #expect(viewModel.pendingAudioAttachment?.data == (hasAttachments ? audio.data : nil))
        #expect(viewModel.pendingImageAttachments.first?.data == (hasAttachments ? image.data : nil))
        #expect(viewModel.pendingFileAttachments.first?.data == (hasAttachments ? file.data : nil))

        config.chatSendDelaySeconds = previousDelay
        config.chatComposerDraft = previousDraft
        await delayedTask?.value
        await config.flushPendingWrites()
    }
}
