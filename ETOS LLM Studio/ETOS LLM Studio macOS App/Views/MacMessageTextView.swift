import AppKit
import MarkdownUI
import SwiftUI

struct MacMessageTextView: View {
    let text: MacPreparedMessageText
    var fallback = Color.primary
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.macChatTextPalette) private var palette

    var body: some View {
        Group {
            if let colored = colorScheme == .dark ? text.darkRules : text.lightRules { Text(colored) }
            else if let markdown = text.markdown {
                Markdown(markdown)
                    .markdownSoftBreakMode(.lineBreak)
                    .markdownTextStyle {
                        if let name = text.typography.bodyName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.default)) }
                        FontSize(CGFloat(text.typography.pointSize))
                        ForegroundColor(palette.body ?? fallback)
                    }
                    .markdownTextStyle(\.emphasis) {
                        if let name = text.typography.emphasisName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.default)) }
                        FontStyle(.italic)
                        if let color = palette.emphasis { ForegroundColor(color) }
                    }
                    .markdownTextStyle(\.strong) {
                        if let name = text.typography.strongName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.default)) }
                        FontWeight(.semibold)
                        if let color = palette.strong { ForegroundColor(color) }
                    }
                    .markdownTextStyle(\.code) {
                        if let name = text.typography.codeName { FontFamily(.custom(name)) }
                        else { FontFamily(.system(.monospaced)) }
                        if let color = palette.code { ForegroundColor(color) }
                    }
                    .markdownBlockStyle(\.codeBlock) { block in
                        GroupBox {
                            VStack(alignment: .leading) {
                                HStack {
                                    if let language = block.language { Text(language).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(block.content, forType: .string)
                                    } label: { Label(NSLocalizedString("复制代码", comment: ""), systemImage: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                }
                                ScrollView(.horizontal) {
                                    block.label.fixedSize(horizontal: true, vertical: true)
                                        .foregroundStyle(palette.code ?? palette.body ?? .primary)
                                }
                            }
                        }
                    }
            } else { Text(text.plain) }
        }
        .textSelection(.enabled)
        .font(text.typography.body)
        .lineSpacing(CGFloat(text.typography.lineSpacing))
        .foregroundStyle(palette.body ?? fallback)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
