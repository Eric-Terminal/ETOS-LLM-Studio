// ============================================================================
// ThirdPartyImportKelivoTests.swift
// ============================================================================
// ThirdPartyImportService Kelivo 导入测试
// - 覆盖 settings.json provider_configs 解析
// - 覆盖 chats.json conversations/messages 解析
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("第三方导入 Kelivo 兼容测试")
struct ThirdPartyImportKelivoTests {

    @Test("Kelivo 目录备份可解析 provider 与会话")
    func testPrepareKelivoImportFromDirectory() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "provider_configs": [
                "kelivo-provider-1": [
                    "name": "Kelivo Gemini",
                    "providerType": "gemini",
                    "baseUrl": "https://generativelanguage.googleapis.com",
                    "apiKey": "kelivo-key",
                    "enabled": true,
                    "models": ["gemini-2.5-pro"]
                ]
            ]
        ]

        let chats: [String: Any] = [
            "conversations": [
                ["id": "conv-1", "title": "Kelivo 测试会话"]
            ],
            "messages": [
                [
                    "id": "kmsg-2",
                    "conversationId": "conv-1",
                    "role": "assistant",
                    "content": "",
                    "reasoningText": "推理内容",
                    "timestamp": 2,
                    "totalTokens": 42
                ],
                [
                    "id": "kmsg-1",
                    "conversationId": "conv-1",
                    "role": "user",
                    "content": "你好",
                    "timestamp": 1
                ]
            ]
        ]

        try JSONSerialization.data(withJSONObject: settings)
            .write(to: sandbox.appendingPathComponent("settings.json"))
        try JSONSerialization.data(withJSONObject: chats)
            .write(to: sandbox.appendingPathComponent("chats.json"))

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .kelivo,
            fileURL: sandbox
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.sessions))
        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.sessions.count == 1)
        #expect(prepared.warnings.isEmpty)

        let provider = prepared.package.providers[0]
        #expect(provider.apiFormat == "gemini")
        #expect(provider.baseURL == "https://generativelanguage.googleapis.com/v1beta")
        #expect(provider.models.map(\.modelName) == ["gemini-2.5-pro"])

        let session = prepared.package.sessions[0]
        #expect(session.session.name == "Kelivo 测试会话")
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[1].role == .assistant)
        #expect(session.messages[1].content == "推理内容")
        #expect(session.messages[1].tokenUsage?.totalTokens == 42)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
