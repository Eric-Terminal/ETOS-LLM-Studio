// ============================================================================
// CopyFeedbackSupportTests.swift
// ============================================================================
// ETOS LLM Studio AppTests
//
// 覆盖 Web Markdown 复制完成后回传原生反馈的桥接约束。
// ============================================================================

import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

struct CopyFeedbackSupportTests {
    @Test("复制完成胶囊使用清晰的成功语义")
    @MainActor
    func copyCompletionNoticeUsesSuccessSemantics() {
        let notice = ChatTransientNotice.copyCompleted

        #expect(notice.message == NSLocalizedString("已复制", comment: "Copy completion notice"))
        #expect(notice.systemImage == "checkmark.circle.fill")
    }

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
