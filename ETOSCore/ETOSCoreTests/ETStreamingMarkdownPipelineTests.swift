// ============================================================================
// ETStreamingMarkdownPipelineTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证流式 Markdown 的稳定区提交、活动区追加与边界重置。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("流式 Markdown 管线")
struct ETStreamingMarkdownPipelineTests {
    @Test("普通段落只在下一段出现后提交")
    func paragraphCommitsAfterNextBlockStarts() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()

        let first = await pipeline.prepare(
            messageID: messageID,
            sourceText: "第一段",
            isFinal: false
        )
        #expect(first.committedBlocks.isEmpty)
        #expect(first.activeBlock?.displayText == "第一段")

        let second = await pipeline.prepare(
            messageID: messageID,
            sourceText: "第一段\n\n第二段",
            isFinal: false
        )
        #expect(second.committedBlocks.count == 1)
        #expect(second.committedBlocks[0].source == "第一段\n\n")
        #expect(second.activeBlock?.displayText == "第二段")
        #expect(second.committedBlocks[0].id.ordinal == 0)
        #expect(second.activeBlock?.id.ordinal == 1)
    }

    @Test("活动段严格追加保留 UTF-16 旧长度")
    func activeAppendReportsPreviousUTF16Length() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        _ = await pipeline.prepare(
            messageID: messageID,
            sourceText: "你好😀",
            isFinal: false
        )

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: "你好😀世界",
            isFinal: false
        )
        #expect(
            snapshot.activeBlock?.updateKind
                == .append(previousUTF16Length: "你好😀".utf16.count)
        )
    }

    @Test("内容替换会重置活动区并清空旧 Block")
    func replacementResetsMessageState() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        _ = await pipeline.prepare(
            messageID: messageID,
            sourceText: "旧段落\n\n旧活动区",
            isFinal: false
        )

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: "全新正文",
            isFinal: false
        )
        #expect(snapshot.committedBlocks.isEmpty)
        #expect(snapshot.activeBlock?.displayText == "全新正文")
        #expect(snapshot.activeBlock?.updateKind == .reset)
        #expect(snapshot.activeBlock?.id.ordinal == 0)
    }

    @Test("围栏代码内部空行不会切断活动 Block")
    func fencedCodeKeepsInternalBlankLinesActive() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let source = "```swift\nlet value = 1\n\nprint(value)"

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: source,
            isFinal: false
        )
        #expect(snapshot.committedBlocks.isEmpty)
        #expect(snapshot.activeBlock?.displayText == "let value = 1\n\nprint(value)")
        #expect(snapshot.activeBlock?.presentation == .code(language: "swift"))
    }

    @Test("已闭合围栏在后续 Block 出现时提交")
    func closedFenceCommitsWhenFollowingBlockArrives() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let source = "```swift\nprint(1)\n```\n后续说明"

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: source,
            isFinal: false
        )
        #expect(snapshot.committedBlocks.count == 1)
        #expect(snapshot.committedBlocks[0].kind == .fencedCode(language: "swift"))
        #expect(snapshot.activeBlock?.displayText == "后续说明")
    }

    @Test("列表空行后的同类项目仍属于同一活动区")
    func looseListRemainsActive() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let source = "1. 第一项\n\n2. 第二项"

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: source,
            isFinal: false
        )
        #expect(snapshot.committedBlocks.isEmpty)
        #expect(snapshot.activeBlock?.source == source)
    }

    @Test("未闭合强调和链接保持原始活动文本")
    func incompleteInlineMarkupIsNotPatched() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let source = "这是 **尚未闭合，并且有 [链接"

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: source,
            isFinal: false
        )
        #expect(snapshot.activeBlock?.displayText == source)
    }

    @Test("Mermaid 围栏使用源码展示类型")
    func mermaidUsesSourcePresentationWhileStreaming() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let source = "```mermaid\ngraph TD\nA-->B"

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: source,
            isFinal: false
        )
        #expect(snapshot.activeBlock?.presentation == .mermaidSource)
        #expect(snapshot.activeBlock?.displayText == "graph TD\nA-->B")
    }

    @Test("结束刷新提交最后活动 Block")
    func finalFlushCommitsLastBlock() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        _ = await pipeline.prepare(
            messageID: messageID,
            sourceText: "最终内容",
            isFinal: false
        )

        let final = await pipeline.prepare(
            messageID: messageID,
            sourceText: "最终内容",
            isFinal: true
        )
        #expect(final.isFinal)
        #expect(final.activeBlock == nil)
        #expect(final.committedBlocks.map(\.source) == ["最终内容"])
    }

    @Test("正文与推理使用互不干扰的流状态")
    func contentAndReasoningUseIndependentStates() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()

        let content = await pipeline.prepare(
            messageID: messageID,
            channel: .content,
            sourceText: "正文",
            isFinal: false
        )
        let reasoning = await pipeline.prepare(
            messageID: messageID,
            channel: .reasoning,
            sourceText: "推理",
            isFinal: false
        )

        #expect(content.channel == .content)
        #expect(reasoning.channel == .reasoning)
        #expect(content.activeBlock?.displayText == "正文")
        #expect(reasoning.activeBlock?.displayText == "推理")
        #expect(content.activeBlock?.id != reasoning.activeBlock?.id)
    }

    @Test("替换正文后的 Block 身份不会复用旧世代")
    func replacementUsesNewBlockGeneration() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let original = await pipeline.prepare(
            messageID: messageID,
            sourceText: "旧段落\n\n旧活动",
            isFinal: false
        )
        let replacement = await pipeline.prepare(
            messageID: messageID,
            sourceText: "新段落\n\n新活动",
            isFinal: false
        )

        #expect(original.committedBlocks.first?.id.generation == 0)
        #expect(replacement.committedBlocks.first?.id.generation == 1)
        #expect(original.committedBlocks.first?.id != replacement.committedBlocks.first?.id)
    }

    @Test("标题、表格和后续段落按稳定空行边界提交")
    func headingAndTableCommitConservatively() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let source = "# 标题\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n后续"

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: source,
            isFinal: false
        )

        #expect(snapshot.committedBlocks.map(\.source) == [
            "# 标题\n\n",
            "| A | B |\n| - | - |\n| 1 | 2 |\n\n"
        ])
        #expect(snapshot.activeBlock?.source == "后续")
    }

    @Test("引用和嵌套列表在同类容器内保持活动")
    func containersRemainActiveAcrossLooseLines() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()

        let quote = await pipeline.prepare(
            messageID: messageID,
            sourceText: "> 第一段\n\n> 第二段",
            isFinal: false
        )
        #expect(quote.committedBlocks.isEmpty)

        let list = await pipeline.prepare(
            messageID: messageID,
            sourceText: "- 项目\n  - 子项目\n\n- 后续项目",
            isFinal: false
        )
        #expect(list.committedBlocks.isEmpty)
        #expect(list.activeBlock?.updateKind == .reset)
    }

    @Test("波浪线围栏和更长闭合围栏可以稳定提交")
    func tildeFenceAcceptsLongerClosingFence() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let source = "~~~~python\nprint('ok')\n~~~~~\n后续"

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: source,
            isFinal: false
        )

        #expect(snapshot.committedBlocks.first?.kind == .fencedCode(language: "python"))
        #expect(snapshot.activeBlock?.displayText == "后续")
    }

    @Test("组合字符与 Emoji 的追加长度使用 UTF-16")
    func composedUnicodeAppendUsesUTF16() async throws {
        let messageID = UUID()
        let pipeline = ETStreamingMarkdownPipeline()
        let prefix = "e\u{301}👩🏽‍💻日本語"
        _ = await pipeline.prepare(
            messageID: messageID,
            sourceText: prefix,
            isFinal: false
        )

        let snapshot = await pipeline.prepare(
            messageID: messageID,
            sourceText: prefix + "中文",
            isFinal: false
        )

        #expect(snapshot.activeBlock?.updateKind == .append(
            previousUTF16Length: prefix.utf16.count
        ))
    }
}
