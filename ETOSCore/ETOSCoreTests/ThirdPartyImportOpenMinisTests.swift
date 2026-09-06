// ============================================================================
// ThirdPartyImportOpenMinisTests.swift
// ============================================================================
// OpenMinis 兼容导入测试
// - iOS 与 Android 会话导出
// - Provider、MCP 与 Skill 配置
// - 重复导入稳定标识与 ZIP 路径安全边界
// ============================================================================

import Foundation
import Testing
import ZIPFoundation
@testable import ETOSCore

@Suite("第三方导入 OpenMinis 兼容测试")
struct ThirdPartyImportOpenMinisTests {

    @Test("iOS 会话导出保留正文、工具记录和稳定标识")
    func importIOSSessionWithStableIdentifiers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("minis-sessions.json")
        try writeJSON([
            [
                "id": "ios-session-1",
                "title": "OpenMinis iOS",
                "modelId": "gpt-5",
                "messages": [
                    [
                        "role": "user",
                        "createdAt": "2026-08-08T08:00:00Z",
                        "parts": [["type": "text", "text": "你好"]]
                    ],
                    [
                        "role": "assistant",
                        "parts": [
                            ["type": "tool_use", "name": "terminal"],
                            ["type": "tool_result", "output": "done"],
                            ["type": "media"],
                            ["type": "text", "text": "完成"]
                        ],
                        "tokenUsage": ["inputTokens": 12, "outputTokens": 3]
                    ]
                ]
            ]
        ], to: fileURL)

        let first = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: fileURL)
        let second = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: fileURL)
        let firstSession = try #require(first.package.sessions.first)
        let secondSession = try #require(second.package.sessions.first)

        #expect(first.package.options.contains(.sessions))
        #expect(firstSession.session.id == secondSession.session.id)
        #expect(firstSession.messages.map(\.id) == secondSession.messages.map(\.id))
        #expect(firstSession.messages.count == 2)
        #expect(firstSession.messages[1].content.contains("terminal"))
        #expect(firstSession.messages[1].content.contains("done"))
        #expect(firstSession.messages[1].tokenUsage?.promptTokens == 12)
        #expect(first.parsedMessagesCount == 2)
        #expect(first.attachmentPlaceholderCount == 1)
        #expect(first.degradedItemCount == 3)
    }

    @Test("Android 会话导出可解开 parts_json 字符串")
    func importAndroidDoubleEncodedMessageParts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionDirectory = directory.appendingPathComponent("android-chat", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try writeJSON([
            "id": "android-session-1",
            "title": "OpenMinis Android",
            "model_id": "claude-sonnet"
        ], to: sessionDirectory.appendingPathComponent("session.json"))
        try writeJSON([
            [
                "id": "android-message-1",
                "role": "user",
                "content": "[{\"type\":\"text\",\"value\":\"来自 Android\"}]",
                "created_at": 1_786_176_000_000
            ]
        ], to: sessionDirectory.appendingPathComponent("messages.json"))

        let prepared = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: directory)
        let session = try #require(prepared.package.sessions.first)

        #expect(session.session.name == "OpenMinis Android")
        #expect(session.messages.first?.content == "来自 Android")
    }

    @Test("Provider 与本地 stdio MCP 会标记敏感凭据")
    func importProviderAndMCPWithSensitiveCredentials() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJSON([
            "version": 1,
            "instanceId": "provider-1",
            "config": [
                "providerType": "openAIResponses",
                "label": "OpenMinis Provider",
                "apiKey": Data("secret-key".utf8).base64EncodedString(),
                "customBaseURL": "https://api.example.com/v1",
                "models": [[
                    "modelId": "gpt-5",
                    "displayName": "GPT-5",
                    "modalityOverride": 71,
                    "supportsReasoning": true,
                    "overrides": ["displayName": "GPT-5 自定义"]
                ]]
            ]
        ], to: directory.appendingPathComponent("provider.json"))
        try writeJSON([
            "mcpServers": [
                "git": [
                    "command": "uvx",
                    "args": ["mcp-server-git"],
                    "env": ["TOKEN": "mcp-secret"]
                ]
            ]
        ], to: directory.appendingPathComponent("mcp.json"))

        let prepared = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: directory)
        let provider = try #require(prepared.package.providers.first)
        let server = try #require(prepared.package.mcpServers.first)

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.mcpServers))
        #expect(prepared.containsSensitiveCredentials)
        #expect(provider.apiKeys == ["secret-key"])
        let model = try #require(provider.models.first)
        #expect(model.displayName == "GPT-5 自定义")
        #expect(model.inputModalities.contains(.image))
        #expect(model.outputModalities.contains(.image))
        #expect(model.capabilities.contains(.reasoning))
        #expect(server.displayName == "git")
        if case .localStdio(let configuration) = server.transport {
            #expect(configuration.command == "uvx")
            #expect(configuration.arguments == ["mcp-server-git"])
            #expect(configuration.environment["TOKEN"] == "mcp-secret")
        } else {
            Issue.record("OpenMinis stdio MCP 未解析为本地 stdio transport")
        }
    }

    @Test("Skill 目录会导入清单和资源但不执行脚本")
    func importSkillDirectoryWithResources() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let skillDirectory = directory.appendingPathComponent("skills/demo-skill", isDirectory: true)
        let referencesDirectory = skillDirectory.appendingPathComponent("references", isDirectory: true)
        let scriptsDirectory = skillDirectory.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: demo-skill
        description: OpenMinis Skill 导入测试
        ---

        只导入，不执行脚本。
        """.write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "参考资料".write(to: referencesDirectory.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try "print('不应在导入时执行')".write(to: scriptsDirectory.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)

        let prepared = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: directory)
        let skill = try #require(prepared.package.skills.first)

        #expect(prepared.package.options.contains(.skills))
        #expect(skill.name == "demo-skill")
        #expect(Set(skill.files.map(\.relativePath)) == ["SKILL.md", "references/guide.md", "scripts/run.py"])
        #expect(prepared.warnings.contains(where: { $0.contains("不会执行") }))
    }

    @Test("包含路径穿越条目的 ZIP 会整体拒绝")
    func rejectArchivePathTraversal() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(data: Data(), accessMode: .create)
        let payload = Data("{}".utf8)
        try archive.addEntry(
            with: "../unsafe.json",
            type: .file,
            uncompressedSize: Int64(payload.count),
            compressionMethod: .none
        ) { position, size in
            payload.subdata(in: Int(position)..<Int(position) + size)
        }
        let archiveURL = directory.appendingPathComponent("unsafe.zip")
        try #require(archive.data).write(to: archiveURL)

        #expect(throws: ThirdPartyImportError.self) {
            _ = try ThirdPartyImportService.prepareImport(source: .openMinis, fileURL: archiveURL)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openminis-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
