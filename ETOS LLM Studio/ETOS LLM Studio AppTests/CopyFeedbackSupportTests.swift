// ============================================================================
// CopyFeedbackSupportTests.swift
// ============================================================================
// ETOS LLM Studio AppTests
//
// 覆盖 Web Markdown 复制完成后回传原生反馈的桥接约束。
// ============================================================================

import Testing
@testable import ETOS_LLM_Studio_App

struct CopyFeedbackSupportTests {
    @Test("Web Markdown 复制成功后会通知原生反馈层")
    @MainActor
    func webMarkdownCopyReportsNativeCompletion() {
        let configuration = ETMathWebShellConfiguration(
            enableMarkdown: true,
            isOutgoing: false,
            customTextHex: nil,
            customEmphasisTextHex: nil,
            customStrongTextHex: nil,
            customCodeTextHex: nil,
            prefersDarkPalette: false,
            fontScale: 1,
            lineSpacingEm: 0
        )

        #expect(configuration.htmlDocument.contains(
            "window.webkit.messageHandlers.etMathCopy.postMessage(true);"
        ))
    }
}
