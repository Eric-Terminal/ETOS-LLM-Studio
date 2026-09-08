import SwiftUI
import ETOSCore

/// 反馈内容独立于聊天渲染开关；复用渲染器已有的后台 Markdown 预计算。
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
