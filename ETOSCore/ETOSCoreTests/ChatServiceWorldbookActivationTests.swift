import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("实际聊天请求只注入命中条目，多书绑定不会重新开启导入时关闭的递归")
    func requestRespectsImportedWorldbookActivationBoundaries() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        let sessionID = UUID()
        defer {
            store.saveWorldbooks(originalBooks)
            Persistence.deleteSessionArtifacts(sessionID: sessionID)
        }

        let book = try WorldbookImportService().importWorldbook(from: Data("""
        {
          "character_book": {
            "name": "关闭递归的设定书", "scan_depth": 1, "recursive_scanning": false,
            "entries": [
              {"keys": ["启程"], "content": "本轮路线经过树屋和湖泊。"},
              {"keys": ["树屋"], "content": "不应发送的树屋详情"},
              {"keys": ["湖泊"], "content": "不应发送的湖泊详情"},
              {"keys": ["未提及的地点"], "content": "完全无关的未命中条目"}
            ]
          }
        }
        """.utf8), fileName: "card.json")
        let otherBook = Worldbook(name: "开启递归的另一本书", entries: [
            WorldbookEntry(content: "不应跨书发送的详情", keys: ["树屋"])
        ], settings: .init(maxRecursionDepth: 3))
        store.saveWorldbooks([book, otherBook])

        var session = ChatSession(id: sessionID, name: "关键词触发回归", isTemporary: false)
        session.lorebookIDs = [book.id, otherBook.id]
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)
        chatService.messagesForSessionSubject.send([])
        await chatService.sendAndProcessMessage(
            content: "启程", aiTemperature: 0, aiTopP: 1, systemPrompt: "系统提示",
            maxChatHistory: 10, enableStreaming: false, enhancedPrompt: nil,
            enableMemory: false, enableMemoryWrite: false, includeSystemTime: false
        )

        let messages = try #require(mockAdapter.receivedMessages)
        let requestContent = messages.map(\.content).joined(separator: "\n")
        #expect(requestContent.contains("本轮路线经过树屋和湖泊。"))
        #expect(!requestContent.contains("不应发送的树屋详情"))
        #expect(!requestContent.contains("不应发送的湖泊详情"))
        #expect(!requestContent.contains("完全无关的未命中条目"))
        #expect(!requestContent.contains("不应跨书发送的详情"))
        await cleanup()
    }
}
