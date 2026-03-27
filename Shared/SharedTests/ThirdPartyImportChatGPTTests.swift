// ============================================================================
// ThirdPartyImportChatGPTTests.swift
// ============================================================================
// ThirdPartyImportService ChatGPT 导入测试
// - 覆盖 conversations.json mapping 树解析
// - 覆盖角色与内容提取
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("第三方导入 ChatGPT 兼容测试")
struct ThirdPartyImportChatGPTTests {

    @Test("ChatGPT conversations.json 可解析 mapping 对话链")
    func testPrepareChatGPTImportFromMappingJSON() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let conversation: [String: Any] = [
            "id": "chatgpt-conv-1",
            "title": "ChatGPT 测试会话",
            "current_node": "node-2",
            "mapping": [
                "node-1": [
                    "id": "node-1",
                    "parent": NSNull(),
                    "children": ["node-2"],
                    "message": [
                        "id": "msg-1",
                        "author": ["role": "user"],
                        "content": ["parts": ["你好 ChatGPT"]],
                        "create_time": 1
                    ]
                ],
                "node-2": [
                    "id": "node-2",
                    "parent": "node-1",
                    "children": [],
                    "message": [
                        "id": "msg-2",
                        "author": ["role": "assistant"],
                        "content": ["parts": ["你好，我是助手"]],
                        "create_time": 2
                    ]
                ]
            ]
        ]

        let fileURL = sandbox.appendingPathComponent("conversations.json")
        try JSONSerialization.data(withJSONObject: [conversation]).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .chatgpt,
            fileURL: fileURL
        )

        #expect(!prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.sessions))
        #expect(prepared.package.sessions.count == 1)

        let session = prepared.package.sessions[0]
        #expect(session.session.name == "ChatGPT 测试会话")
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[0].content == "你好 ChatGPT")
        #expect(session.messages[1].role == .assistant)
        #expect(session.messages[1].content == "你好，我是助手")
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
