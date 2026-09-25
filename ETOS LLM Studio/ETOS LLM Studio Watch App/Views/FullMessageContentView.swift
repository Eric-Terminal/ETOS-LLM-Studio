// ============================================================================
// FullMessageContentView.swift
// ============================================================================
// 用户消息保留源文本；含公式的助手回复在用户打开后后台准备完整阅读页。
// ============================================================================

import SwiftUI
import ETOSCore

struct FullMessageContentView: View {
    let content: String
    var rendersMath = false

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var mathPageItem: WatchWebHTMLPageItem?

    var body: some View {
        Group {
            if rendersMath {
                if let mathPageItem {
                    WatchWebHTMLPage(item: mathPageItem)
                } else {
                    ProgressView()
                }
            } else {
                ScrollView {
                    Text(content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .etFont(.body)
        .navigationTitle(NSLocalizedString("查看完整内容", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard rendersMath else { return }
            let prefersDarkPalette = colorScheme == .dark
            let fontScale = FontLibrary.effectiveFontScale(
                appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts
            )
            // 解析和 HTML 序列化按需在后台执行，长回复不能阻塞导航动画。
            let html = await Task.detached(priority: .userInitiated) { [content] in
                WatchWebHTMLDocumentFactory.mathDocument(
                    content: ETMathContentParser.normalizedMathDelimiters(in: content),
                    prefersDarkPalette: prefersDarkPalette,
                    fontScale: fontScale
                )
            }.value
            guard !Task.isCancelled else { return }
            mathPageItem = WatchWebHTMLPageItem(
                title: NSLocalizedString("查看完整内容", comment: ""),
                html: html
            )
        }
    }
}
