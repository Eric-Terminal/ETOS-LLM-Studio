import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("世界书扫描与发送文本使用相同的宏展开结果，并保留字面宏", arguments: ["topic", "enhanced", "message"], [false, true])
    func worldbookScansRenderedPromptMacros(location: String, literal: Bool) async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        let sessionID = UUID()
        defer {
            store.saveWorldbooks(originalBooks)
            Persistence.deleteSessionArtifacts(sessionID: sessionID)
        }

        let renderedEntry = "匹配展开后会话名称的条目正文"
        let literalEntry = "匹配双括号字面宏的条目正文"
        let book = Worldbook(name: "宏匹配回归", entries: [
            WorldbookEntry(content: renderedEntry, keys: ["玫瑰别馆"]),
            WorldbookEntry(content: literalEntry, keys: ["{{chat_name}}"])
        ], settings: .init(scanDepth: 1, maxRecursionDepth: 0))
        store.saveWorldbooks([book])
        let template = literal ? "{{{chat_name}}}" : "{{chat_name}}"
        var session = ChatSession(id: sessionID, name: "玫瑰别馆", isTemporary: false)
        session.lorebookIDs = [book.id]
        session.topicPrompt = location == "topic" ? template : nil
        session.enhancedPrompt = location == "enhanced" ? template : nil
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)
        chatService.messagesForSessionSubject.send([])
        await chatService.sendAndProcessMessage(
            content: location == "message" ? template : "普通问候",
            aiTemperature: 0, aiTopP: 1, systemPrompt: "系统提示",
            maxChatHistory: 10, enableStreaming: false, enhancedPrompt: nil,
            enableMemory: false, enableMemoryWrite: false, includeSystemTime: false
        )

        let requestContent = try #require(mockAdapter.receivedMessages).map(\.content).joined(separator: "\n")
        #expect(requestContent.contains(literal ? "{{chat_name}}" : "玫瑰别馆"))
        #expect(requestContent.contains(renderedEntry) == !literal)
        #expect(requestContent.contains(literalEntry) == literal)
        #expect(!requestContent.contains("\u{E000}ETOS.literal:"))
        await cleanup()
    }

    @Test("实际聊天请求按关键词决定是否注入，多书绑定不会重新开启导入时关闭的递归", arguments: ["启程", "普通问候"])
    func requestRespectsImportedWorldbookActivationBoundaries(userMessage: String) async throws {
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
            content: userMessage, aiTemperature: 0, aiTopP: 1, systemPrompt: "系统提示",
            maxChatHistory: 10, enableStreaming: false, enhancedPrompt: nil,
            enableMemory: false, enableMemoryWrite: false, includeSystemTime: false
        )

        let messages = try #require(mockAdapter.receivedMessages)
        let requestContent = messages.map(\.content).joined(separator: "\n")
        #expect(requestContent.contains("本轮路线经过树屋和湖泊。") == (userMessage == "启程"))
        #expect(!requestContent.contains("不应发送的树屋详情"))
        #expect(!requestContent.contains("不应发送的湖泊详情"))
        #expect(!requestContent.contains("完全无关的未命中条目"))
        #expect(!requestContent.contains("不应跨书发送的详情"))
        await cleanup()
    }
}
