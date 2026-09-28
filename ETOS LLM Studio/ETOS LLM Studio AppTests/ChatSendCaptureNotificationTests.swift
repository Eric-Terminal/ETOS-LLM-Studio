import Combine
import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("iOS 发送捕获通知", .serialized)
struct ChatSendCaptureNotificationTests {
    @Test("真实提交同步防重且仅通知输入，早失败按原会话释放占位", arguments: [false, true])
    func submissionIsLocalAndFailedSendReleasesItsOwnSession(switchesSession: Bool) async {
        let config = AppConfigStore.shared
        let previousDelay = config.chatSendDelaySeconds
        let previousDraft = config.chatComposerDraft
        let service = ChatService(adapters: [:])
        let viewModel = ChatViewModel(chatService: service)
        viewModel.cancellables.removeAll()
        await viewModel.waitForBackgroundImage()
        // 初始化加载独立于 Combine 订阅；计数从提示词与记忆快照均发布完之后开始。
        await viewModel.globalSystemPromptReloadTask?.value
        await viewModel.conversationMemoryReloadTask?.value
        // 指定一个不存在的目标，真实 Core 入口会在网络与模型准备前失败。
        let sourceSession = ChatSession(id: UUID(), name: "提交失败来源")
        let nextSession = ChatSession(id: UUID(), name: "提交期间切换")
        viewModel.currentSession = sourceSession
        viewModel.runningSessionIDs = []
        config.chatSendDelaySeconds = 0
        viewModel.userInput = "第一条待提交正文"
        var rootChanges = 0, inputChanges = 0
        let completion = AsyncStream.makeStream(of: Bool.self)
        let subscriptions = [
            viewModel.objectWillChange.sink { rootChanges += 1 },
            viewModel.sendSubmissionState.objectWillChange.sink { inputChanges += 1 },
            viewModel.sendSubmissionState.objectWillChange.receive(on: DispatchQueue.main).sink {
                if !viewModel.sendSubmissionState.isPending(for: sourceSession.id) {
                    completion.continuation.yield(true)
                    completion.continuation.finish()
                }
            }
        ]
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            completion.continuation.finish()
        }

        viewModel.sendMessage()
        #expect(viewModel.isSendSubmissionPending && viewModel.userInput.isEmpty)
        #expect(rootChanges == 0)
        #expect(inputChanges == 1)
        viewModel.userInput = "等待期间新输入"
        viewModel.sendMessage()
        #expect(viewModel.userInput == "等待期间新输入")
        #expect(rootChanges == 0)
        #expect(inputChanges == 1)

        var nextToken: UUID?
        if switchesSession {
            viewModel.currentSession = nextSession
            #expect(!viewModel.isSendSubmissionPending)
            nextToken = viewModel.sendSubmissionState.begin(for: nextSession.id)
            #expect(nextToken != nil && viewModel.isSendSubmissionPending)
        }
        let expectedRootChanges = rootChanges
        let expectedInputChanges = switchesSession ? 3 : 2
        var iterator = completion.stream.makeAsyncIterator()
        let didRelease: Bool? = await iterator.next()
        #expect(didRelease == true)
        #expect(!viewModel.sendSubmissionState.isPending(for: sourceSession.id))
        #expect(viewModel.isSendSubmissionPending == switchesSession)
        #expect(viewModel.userInput == "等待期间新输入")
        #expect(rootChanges == expectedRootChanges)
        #expect(inputChanges == expectedInputChanges)
        timeout.cancel()
        await timeout.value
        subscriptions.forEach { $0.cancel() }
        completion.continuation.finish()
        if let nextToken { viewModel.sendSubmissionState.finish(for: nextSession.id, token: nextToken) }
        config.chatSendDelaySeconds = previousDelay
        config.chatComposerDraft = previousDraft
        await config.flushPendingWrites()
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
        await Task.detached { Persistence.deleteSessionArtifacts(sessionID: sourceSession.id) }.value
    }

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
