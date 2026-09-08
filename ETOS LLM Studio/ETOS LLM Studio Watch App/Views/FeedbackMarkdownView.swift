import SwiftUI
import ETOSCore

/// 手表正文完整展开，避免 List 压缩长文本后没有入口读取余下内容。
struct FeedbackMarkdownView: View {
    let content: String

    var body: some View {
        ETAdvancedMarkdownRenderer(
            content: content,
            preparedContent: nil,
            enableMarkdown: true,
            isOutgoing: false,
            enableAdvancedRenderer: false,
            enableMathRendering: false,
            customTextColor: nil
        )
        .lineLimit(nil)
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
