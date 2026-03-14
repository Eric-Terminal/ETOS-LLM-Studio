// ============================================================================
// MCPToolResultFormatterTests.swift
// ============================================================================
// MCPToolResultFormatter 测试文件
// - 覆盖 MCP 标准包裹结构提取
// - 覆盖摘要与原始返回回退逻辑
// ============================================================================

import Testing
@testable import Shared

@Suite("MCP 工具结果展示格式化测试")
struct MCPToolResultFormatterTests {

    @Test("标准 MCP 文本结果会提取正文并保留原始返回")
    func testStructuredEnvelopeExtractsPrimaryContent() {
        let raw = #"{"content":[{"type":"text","text":"第一行\n第二行"}],"meta":{"source":"demo"}}"#

        let display = MCPToolResultFormatter.displayModel(from: raw)

        #expect(display.summaryText == "第一行 第二行")
        #expect(display.primaryContentText == "第一行\n第二行")
        #expect(display.rawDisplayText.contains(#""content""#))
        #expect(display.isStructuredMCPEnvelope)
        #expect(display.shouldShowRawSection)
    }

    @Test("标准 MCP 结果缺少文本时会回退结构摘要")
    func testStructuredEnvelopeFallsBackToStructureSummary() {
        let raw = #"{"content":[{"type":"image","mimeType":"image/png"}],"meta":{"source":"demo"}}"#

        let display = MCPToolResultFormatter.displayModel(from: raw)

        #expect(display.summaryText == "返回 MCP 内容（1 段）")
        #expect(display.primaryContentText == nil)
        #expect(display.rawDisplayText.contains(#""mimeType""#))
        #expect(display.isStructuredMCPEnvelope)
        #expect(display.shouldShowRawSection)
    }

    @Test("非法 JSON 会回退为原始文本展示")
    func testInvalidJSONFallsBackToPlainText() {
        let raw = "执行完成：42"

        let display = MCPToolResultFormatter.displayModel(from: raw)

        #expect(display.summaryText == "执行完成：42")
        #expect(display.primaryContentText == "执行完成：42")
        #expect(display.rawDisplayText == "执行完成：42")
        #expect(!display.isStructuredMCPEnvelope)
        #expect(!display.shouldShowRawSection)
    }

    @Test("非 MCP JSON 会展示结构摘要并保留原始返回")
    func testNonStructuredJSONUsesStructureSummary() {
        let raw = #"{"count":2,"status":"ok"}"#

        let display = MCPToolResultFormatter.displayModel(from: raw)

        #expect(display.summaryText == "返回 JSON 数据（2 个字段）")
        #expect(display.primaryContentText == nil)
        #expect(display.rawDisplayText.contains("\n"))
        #expect(!display.isStructuredMCPEnvelope)
        #expect(display.shouldShowRawSection)
    }

    @Test("超长摘要会按限制截断")
    func testSummaryIsTruncatedWhenLimitExceeded() {
        let raw = "0123456789abcdef"

        let display = MCPToolResultFormatter.displayModel(from: raw, summaryLimit: 10)

        #expect(display.summaryText == "0123456789...")
    }
}
