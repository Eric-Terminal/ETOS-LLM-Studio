// ============================================================================
// ChatTranscriptExportServiceTests.swift
// ============================================================================
// ChatTranscriptExportServiceTests 测试文件
// - 覆盖会话导出的格式内容与 PNG 长图文件
// - 覆盖“截至某条消息”与任意多选消息的范围裁剪行为
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

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

    @Test("不包含思考导出时会移除推理段落并标记文件名")
    func testExportWithoutReasoningRemovesReasoningSections() throws {
        let service = ChatTranscriptExportService()

        var message = ChatMessage(role: .assistant, content: "正文")
        message.reasoningContent = "这段推理不应被导出"

        let output = try service.export(
            session: ChatSession(id: UUID(), name: "思考开关"),
            messages: [message],
            format: .markdown,
            includeReasoning: false,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )

        let text = String(decoding: output.data, as: UTF8.self)
        #expect(output.suggestedFileName.contains("不含思考"))
        #expect(text.contains("思考/推理：不包含"))
        #expect(!text.contains("### 推理"))
        #expect(!text.contains("这段推理不应被导出"))
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

    @Test("导出所选消息时会保留原始顺序并排除未选内容")
    func testExportSelectedMessagesPreservesSourceOrder() throws {
        let service = ChatTranscriptExportService()
        let first = ChatMessage(id: UUID(), role: .user, content: "第一条")
        let second = ChatMessage(id: UUID(), role: .assistant, content: "第二条")
        let third = ChatMessage(id: UUID(), role: .user, content: "第三条")

        let output = try service.export(
            session: ChatSession(id: UUID(), name: "多选范围"),
            messages: [first, second, third],
            format: .text,
            selectedMessageIDs: [third.id, first.id],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_150)
        )

        let text = String(decoding: output.data, as: UTF8.self)
        #expect(output.suggestedFileName.contains("已选2条"))
        #expect(text.contains("第一条"))
        #expect(!text.contains("第二条"))
        #expect(text.contains("第三条"))
        let firstRange = try #require(text.range(of: "第一条"))
        let thirdRange = try #require(text.range(of: "第三条"))
        #expect(firstRange.lowerBound < thirdRange.lowerBound)
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

    @Test("PNG 导出会生成聊天长图并过滤系统消息")
    func testPNGExportHasValidHeaderAndFiltersSystemMessages() throws {
        let service = ChatTranscriptExportService()
        let system = ChatMessage(role: .system, content: "不可见的系统提示词")
        let user = ChatMessage(role: .user, content: "可见消息")
        let output = try service.export(
            session: ChatSession(id: UUID(), name: "长图会话"),
            messages: [system, user],
            format: .png,
            imageStyle: ChatTranscriptImageStyle(subtitle: "Test"),
            exportedAt: Date(timeIntervalSince1970: 1_700_000_250)
        )

        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(output.suggestedFileName.hasSuffix(".png"))
        #expect(output.data.starts(with: pngHeader))
    }

    @Test("PNG 范围只有系统消息时不会生成图片")
    func testPNGExportRejectsSystemOnlyScope() {
        let system = ChatMessage(role: .system, content: "不可见的系统提示词")

        #expect(throws: ChatTranscriptExportError.emptyMessages) {
            try ChatTranscriptExportService().export(
                session: nil,
                messages: [system],
                format: .png,
                exportedAt: Date(timeIntervalSince1970: 1_700_000_275)
            )
        }
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
