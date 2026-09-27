import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
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
                callbackCount += 1
                prepared = presentation
                let ids = Set(presentation.messageIDsBySource.values)
                wasPublishedBeforeCallback = service.messagesSnapshot(for: session.id).contains { ids.contains($0.id) }
            }
        )
        let presentation = try #require(prepared)
        let messages = Persistence.loadMessages(for: session.id).filter { $0.role == .user }
        #expect(callbackCount == 1)
        #expect(!wasPublishedBeforeCallback)
        #expect(presentation.sessionID == session.id)
        #expect(service.currentSessionSubject.value?.id == browsingSession.id)
        #expect(Persistence.loadMessages(for: browsingSession.id).isEmpty)
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
}
