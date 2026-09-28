import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @MainActor
    @Test("普通提交先交身份，第一份消息结构一次包含全部来源与回复占位")
    func sendPublishesCompleteMessageBatchAfterPresentation() async throws {
        enum SubmissionEvent: Sendable {
            case prepared(ChatSendPresentation)
            case published([ChatMessage])
        }
        await cleanup()
        let session = createPermanentTestSession(name: "整组发布")
        let service = try #require(chatService)
        defer { service.deleteSessions([session]) }
        setupMockResponsesForChatAndTitle()
        let files = (0..<2).map { index in
            FileAttachment(
                data: Data("附件 \(index)".utf8), mimeType: "text/plain",
                fileName: "batch-source-\(UUID().uuidString).txt"
            )
        }
        let events = AsyncStream<SubmissionEvent>.makeStream()
        let subscription = service.messagesForSessionSubject.sink {
            events.continuation.yield(.published($0))
        }
        defer { subscription.cancel() }
        await service.sendAndProcessMessage(
            content: "同次提交的正文", aiTemperature: 0, aiTopP: 1,
            systemPrompt: "", maxChatHistory: 5, enableStreaming: false,
            enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false,
            includeSystemTime: false, fileAttachments: files, targetSessionID: session.id,
            requestedLocalAgentMode: .chat,
            onMessagesPrepared: { events.continuation.yield(.prepared($0)) }
        )
        subscription.cancel()
        events.continuation.finish()

        var presentation: ChatSendPresentation?
        var firstPublishedMessages: [ChatMessage]?
        var lastPublishedMessages: [ChatMessage]?
        var publishedBeforeIdentity = false
        var structures: [[UUID]] = []
        for await event in events.stream {
            switch event {
            case .prepared(let value):
                presentation = value
            case .published(let messages):
                guard !messages.isEmpty else { continue }
                if presentation == nil { publishedBeforeIdentity = true }
                if firstPublishedMessages == nil { firstPublishedMessages = messages }
                lastPublishedMessages = messages
                // 内容与指标仍可正常发布；这里只记录消息身份结构的变化。
                let ids = messages.map(\.id)
                if structures.last != ids { structures.append(ids) }
            }
        }
        let prepared = try #require(presentation)
        let firstMessages = try #require(firstPublishedMessages)
        #expect(!publishedBeforeIdentity)
        #expect(prepared.sessionID == session.id)
        #expect(prepared.messageIDsBySource.count == 3)
        #expect(firstMessages.map(\.role) == [.user, .user, .user, .assistant])
        #expect(firstMessages.filter { $0.role == .user }.map(\.id) == [
            prepared.messageIDsBySource[.file(files[0].id)],
            prepared.messageIDsBySource[.file(files[1].id)],
            prepared.messageIDsBySource[.text]
        ].compactMap { $0 })
        #expect(firstMessages.last?.content == "")
        #expect(firstMessages.last?.responseGroupID == prepared.responseGroupID)
        #expect(lastPublishedMessages?.last?.id == firstMessages.last?.id)
        #expect(lastPublishedMessages?.last?.content == "聊天回复")
        #expect(structures == [firstMessages.map(\.id)])
        #expect(Persistence.loadMessages(for: session.id).map(\.id) == firstMessages.map(\.id))
        #expect(mockAdapter.receivedMessages != nil)
    }

    @MainActor
    @Test("发送来源在附件拆分、同名文件复用和正文正则改写后仍对应准确消息", arguments: [false, true])
    func sendPresentationPreservesSourceIdentity(includesText: Bool) async throws {
        await cleanup()
        let session = createPermanentTestSession(name: "发送来源映射")
        let browsingSession = createPermanentTestSession(name: "发送后切换的会话")
        let key = AppConfigKey.messageRegexRules.rawValue
        let savedRules = AppConfigStore.shared.snapshot(includeLocalOnly: true)[key]
        defer {
            AppConfigStore.shared.apply(snapshot: [key: savedRules ?? AppConfigKey.messageRegexRules.defaultValue.anyValue])
            MessageRegexRuleStore.shared.reload()
            chatService.deleteSessions([session, browsingSession])
        }
        let rules = [MessageRegexRule(name: "发送替换", pattern: "原始草稿", replacement: "保存后的正文", scopes: [.user], mode: .persist)]
        let raw = try #require(String(data: JSONEncoder().encode(rules), encoding: .utf8))
        AppConfigStore.shared.apply(snapshot: [key: raw])
        MessageRegexRuleStore.shared.reload()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "已收到")

        let fileName = "send-source-\(UUID().uuidString).txt"
        let files = (0..<2).map { _ in
            FileAttachment(data: Data("同一份内容".utf8), mimeType: "text/plain", fileName: fileName)
        }
        let image = ImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", fileName: "send-source-\(UUID().uuidString).png")
        let audio = AudioAttachment(data: Data([0, 1, 2]), mimeType: "audio/m4a", format: "m4a", fileName: "voice.m4a")
        let selectedModelID = try #require(chatService.selectedModelSubject.value?.id)
        let nextModel = try #require(activatedChatModels().first { $0.id != selectedModelID })
        var prepared: ChatSendPresentation?
        var callbackCount = 0
        var wasPublishedBeforeCallback = false
        let service = try #require(chatService)
        await service.sendAndProcessMessage(
            content: includesText ? "原始草稿" : "",
            aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5,
            enableStreaming: false, enhancedPrompt: nil, enableMemory: false,
            enableMemoryWrite: false, includeSystemTime: false,
            audioAttachment: audio, imageAttachments: [image], fileAttachments: files,
            targetSessionID: session.id,
            onMessagesPrepared: { presentation in
                MainActor.assertIsolated()
                callbackCount += 1
                prepared = presentation
                let ids = Set(presentation.messageIDsBySource.values)
                wasPublishedBeforeCallback = service.messagesSnapshot(for: session.id).contains { ids.contains($0.id) }
                service.setSelectedModel(nextModel)
            }
        )
        let presentation = try #require(prepared)
        let messages = Persistence.loadMessages(for: session.id).filter { $0.role == .user }
        #expect(callbackCount == 1)
        #expect(!wasPublishedBeforeCallback)
        #expect(presentation.sessionID == session.id)
        #expect(service.currentSessionSubject.value?.id == browsingSession.id)
        #expect(Persistence.loadMessages(for: browsingSession.id).isEmpty)
        #expect(mockAdapter.receivedChatModel?.id == selectedModelID)
        #expect(presentation.messageIDsBySource.count == (includesText ? 5 : 4))
        #expect(Set(presentation.messageIDsBySource.values) == Set(messages.map(\.id)))
        #expect(presentation.messageIDsBySource[.audio(audio.id)] == messages.first?.id)
        #expect(presentation.messageIDsBySource[.image(image.id)] == messages.first { $0.imageFileNames != nil }?.id)
        let fileMessages = messages.filter { $0.fileFileNames != nil }
        #expect(fileMessages.count == 2)
        #expect(fileMessages.map { $0.fileFileNames?.first } == [fileName, fileName])
        #expect(presentation.messageIDsBySource[.file(files[0].id)] == fileMessages.first?.id)
        #expect(presentation.messageIDsBySource[.file(files[1].id)] == fileMessages.last?.id)
        #expect(presentation.responseGroupID == messages.last?.id)
        if includesText {
            #expect(messages.last?.content == "保存后的正文")
            #expect(presentation.messageIDsBySource[.text] == messages.last?.id)
        } else {
            #expect(presentation.messageIDsBySource[.text] == nil)
        }
    }

    @MainActor
    @Test("附件写入失败只排除失败来源，全部失败时不交出身份", arguments: [false, true])
    func failedAttachmentPreparationPreservesSuccessfulSources(hasValidContent: Bool) async throws {
        await cleanup()
        let session = createPermanentTestSession(name: "附件准备失败")
        let browsingSession = createPermanentTestSession(name: "独立浏览会话")
        defer { chatService.deleteSessions([session, browsingSession]) }
        setupMockResponsesForChatAndTitle()
        // 不修改共享目录权限；不存在的父目录与超出文件系统上限的单组件稳定导致写入失败。
        let failedImage = ImageAttachment(
            data: Data([0, 1]), mimeType: "image/png",
            fileName: "missing-\(UUID().uuidString)/image.png"
        )
        let failedFile = FileAttachment(
            data: Data([2, 3]), mimeType: "text/plain", fileName: String(repeating: "x", count: 300) + ".txt"
        )
        let validFile = FileAttachment(
            data: Data("成功附件".utf8), mimeType: "text/plain", fileName: "prepared-\(UUID().uuidString).txt"
        )
        var presentation: ChatSendPresentation?
        var callbackCount = 0
        let service = try #require(chatService)
        await service.sendAndProcessMessage(
            content: hasValidContent ? "保留正文" : "",
            aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5,
            enableStreaming: false, enhancedPrompt: nil, enableMemory: false,
            enableMemoryWrite: false, includeSystemTime: false,
            imageAttachments: [failedImage],
            fileAttachments: hasValidContent ? [failedFile, validFile] : [failedFile],
            targetSessionID: session.id,
            onMessagesPrepared: { value in
                MainActor.assertIsolated()
                callbackCount += 1
                presentation = value
                #expect(service.messagesSnapshot(for: session.id).allSatisfy { $0.role != .user })
            }
        )
        if !hasValidContent {
            #expect(service.messagesSnapshot(for: session.id).contains { $0.role == .error })
            // 错误先进入运行时快照，再排队落库；数据库断言必须等待同一写队列的屏障。
            await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
        }
        let messages = Persistence.loadMessages(for: session.id)
        let userMessages = messages.filter { $0.role == .user }
        #expect(service.currentSessionSubject.value?.id == browsingSession.id)
        #expect(Persistence.loadMessages(for: browsingSession.id).isEmpty)
        if hasValidContent {
            let prepared = try #require(presentation)
            let fileMessage = try #require(userMessages.first)
            let textMessage = try #require(userMessages.last)
            #expect(callbackCount == 1)
            #expect(prepared.sessionID == session.id)
            #expect(userMessages.count == 2)
            #expect(userMessages.first?.fileFileNames == [validFile.fileName])
            #expect(userMessages.last?.content == "保留正文")
            #expect(prepared.messageIDsBySource == [
                .file(validFile.id): fileMessage.id,
                .text: textMessage.id
            ])
            #expect(prepared.responseGroupID == userMessages.last?.id)
            #expect(Persistence.loadFile(fileName: validFile.fileName) == validFile.data)
        } else {
            #expect(callbackCount == 0)
            #expect(presentation == nil)
            #expect(userMessages.isEmpty)
            #expect(messages.contains { $0.role == .error })
            #expect(mockAdapter.receivedMessages == nil)
        }
    }
}
