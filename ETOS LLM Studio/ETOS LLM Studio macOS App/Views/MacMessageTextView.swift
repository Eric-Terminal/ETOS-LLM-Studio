import AppKit
import MarkdownUI
import SwiftUI

struct MacMessageTextView: View {
    let text: MacPreparedMessageText

    var body: some View {
        Group {
            if let markdown = text.markdown {
                Markdown(markdown)
                    .markdownSoftBreakMode(.lineBreak)
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
                                ScrollView(.horizontal) { block.label.fixedSize(horizontal: true, vertical: true) }
                            }
                        }
                    }
            } else { Text(text.plain) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
