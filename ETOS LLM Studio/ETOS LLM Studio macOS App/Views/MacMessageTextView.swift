import AppKit
import MarkdownUI
import SwiftUI

struct MacMessageTextView: View {
    let text: MacPreparedMessageText
    var fallback = Color.primary
    var typographyOverride: MacTextTypography? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.macChatTextPalette) private var palette
    private var typography: MacTextTypography { typographyOverride ?? text.typography }

    var body: some View {
        Group {
            if let stream = text.stream {
                MacStreamingMarkdownView(snapshot: stream, typography: typography, fallback: fallback)
            } else if let colored = colorScheme == .dark ? text.darkRules : text.lightRules {
                Text(colored)
            } else if let advanced = text.advanced {
                MacAdvancedMarkdownView(sourceID: text.id, source: advanced, typography: typography, palette: palette) {
                    nativeText
                }
            } else { nativeText }
        }
        .textSelection(.enabled)
        .font(typography.body)
        .lineSpacing(CGFloat(typography.lineSpacing))
        .foregroundStyle(palette.body ?? fallback)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var nativeText: some View {
        if let colored = colorScheme == .dark ? text.darkRules : text.lightRules { Text(colored) }
        else if let markdown = text.markdown {
                Markdown(markdown)
                    .markdownSoftBreakMode(.lineBreak)
                    .markdownTextStyle {
                        if let name = typography.bodyName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.default)) }
                        FontSize(CGFloat(typography.pointSize))
                        ForegroundColor(palette.body ?? fallback)
                    }
                    .markdownTextStyle(\.emphasis) {
                        if let name = typography.emphasisName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.default)) }
                        FontStyle(.italic)
                        if let color = palette.emphasis { ForegroundColor(color) }
                    }
                    .markdownTextStyle(\.strong) {
                        if let name = typography.strongName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.default)) }
                        FontWeight(.semibold)
                        if let color = palette.strong { ForegroundColor(color) }
                    }
                    .markdownTextStyle(\.code) {
                        if let name = typography.codeName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.monospaced)) }
                        if let color = palette.code { ForegroundColor(color) }
                    }
                    .markdownBlockStyle(\.codeBlock) { block in
                        MacMarkdownCodeBlock(sourceID: text.id, content: block.content, language: block.language, label: block.label,
                            color: palette.code ?? palette.body ?? fallback, highlights: palette.code == nil)
                            .font(typography.codeName.map { Font.custom($0, size: CGFloat(typography.pointSize)) }
                                  ?? Font.system(size: CGFloat(typography.pointSize), design: .monospaced))
                    }
        } else { Text(text.plain) }
    }
}
