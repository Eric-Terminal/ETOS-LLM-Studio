import AppKit
import ETOSCore
import SwiftUI

struct MacMarkdownCodeBlock<LabelContent: View>: View {
    let content: String
    let language: String?
    let label: LabelContent
    let color: Color
    let highlights: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = true

    var body: some View {
        GroupBox {
            VStack(alignment: .leading) {
                HStack {
                    if let language { Text(language).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: { Label(NSLocalizedString("复制代码", comment: ""), systemImage: "doc.on.doc") }
                    Button { expanded.toggle() } label: {
                        Label(expanded ? NSLocalizedString("收起", comment: "") : NSLocalizedString("展开", comment: ""),
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                }
                .buttonStyle(.borderless)
                if expanded {
                    ETPagedTextContent(text: content) { page in
                        ScrollView(.horizontal) {
                            ETHighlightedCodePage(
                                content: page, language: language, color: color, isOutgoing: false,
                                prefersDarkPalette: colorScheme == .dark,
                                highlights: highlights, highlightLimit: 12_000
                            )
                            .fixedSize(horizontal: true, vertical: true)
                        }
                    } exportContent: {
                        ScrollView(.horizontal) {
                            label.foregroundStyle(color)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
