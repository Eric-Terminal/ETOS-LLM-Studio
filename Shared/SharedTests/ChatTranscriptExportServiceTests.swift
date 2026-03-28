// ============================================================================
// ChatTranscriptExportServiceTests.swift
// ============================================================================
// ChatTranscriptExportServiceTests 测试文件
// - 覆盖会话导出的格式内容
// - 覆盖“截至某条消息”范围裁剪行为
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("会话导出服务测试")
struct ChatTranscriptExportServiceTests {

    @Test("Markdown 导出包含角色与工具调用")
    func testMarkdownExportContainsMessageSections() throws {
        let service = ChatTranscriptExportService()
        let session = ChatSession(id: UUID(), name: "测试会话", topicPrompt: "话题提示", enhancedPrompt: "增强提示")

        var assistant = ChatMessage(role: .assistant, content: "这是回复")
        assistant.reasoningContent = "这是推理"
        assistant.toolCalls = [
            InternalToolCall(id: "call_1", toolName: "search", arguments: "{\"q\":\"swift\"}", result: "ok")
        ]

        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "你好"),
            assistant
        ]

        let output = try service.export(
            session: session,
            messages: messages,
            format: .markdown,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let text = String(decoding: output.data, as: UTF8.self)
        #expect(output.suggestedFileName.hasSuffix(".md"))
        #expect(text.contains("## 1. 用户"))
        #expect(text.contains("## 2. 助手"))
        #expect(text.contains("### 工具调用"))
        #expect(text.contains("search"))
    }

    @Test("截至指定消息导出时只包含上文")
    func testExportUpToMessageTruncatesFollowingMessages() throws {
        let service = ChatTranscriptExportService()

        let first = ChatMessage(id: UUID(), role: .user, content: "第一条")
        let second = ChatMessage(id: UUID(), role: .assistant, content: "第二条")
        let third = ChatMessage(id: UUID(), role: .user, content: "第三条")

        let output = try service.export(
            session: ChatSession(id: UUID(), name: "范围测试"),
            messages: [first, second, third],
            format: .text,
            upToMessageID: second.id,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let text = String(decoding: output.data, as: UTF8.self)
        #expect(output.suggestedFileName.contains("截至第2条"))
        #expect(text.contains("第一条"))
        #expect(text.contains("第二条"))
        #expect(!text.contains("第三条"))
    }

    @Test("PDF 导出会生成有效文件头")
    func testPDFExportHasValidHeader() throws {
        let service = ChatTranscriptExportService()
        let output = try service.export(
            session: ChatSession(id: UUID(), name: "PDF会话"),
            messages: [ChatMessage(role: .user, content: "PDF 内容")],
            format: .pdf,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let header = Data([0x25, 0x50, 0x44, 0x46]) // %PDF
        #expect(output.suggestedFileName.hasSuffix(".pdf"))
        #expect(output.data.starts(with: header))
    }

    @Test("目标消息不存在时返回错误")
    func testExportThrowsWhenTargetMessageMissing() {
        let service = ChatTranscriptExportService()
        let message = ChatMessage(role: .user, content: "A")

        #expect(throws: ChatTranscriptExportError.self) {
            try service.export(
                session: nil,
                messages: [message],
                format: .text,
                upToMessageID: UUID(),
                exportedAt: Date(timeIntervalSince1970: 1_700_000_300)
            )
        }
    }
}
