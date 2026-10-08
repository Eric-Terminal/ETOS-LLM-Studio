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
                    .markdownTextStyle { ForegroundColor(palette.body ?? fallback) }
                    .markdownTextStyle(\.emphasis) {
                        FontStyle(.italic)
                        if let color = palette.emphasis { ForegroundColor(color) }
                    }
                    .markdownTextStyle(\.strong) {
                        FontWeight(.semibold)
                        if let color = palette.strong { ForegroundColor(color) }
                    }
                    .markdownTextStyle(\.code) {
                        FontFamily(.system(.monospaced))
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
        .foregroundStyle(palette.body ?? fallback)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
