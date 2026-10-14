import AppKit
import SwiftUI

struct MacMarkdownCodeBlock<LabelContent: View>: View {
    let sourceID: UUID
    let content: String
    let language: String?
    let label: LabelContent
    let color: Color
    let highlights: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var prepared: Prepared?
    @State private var expanded = true

    private struct Request: Hashable, Sendable {
        let sourceID: UUID
        let color: Color
        let dark: Bool
        let highlights: Bool
    }
    private struct Prepared: @unchecked Sendable {
        let request: Request
        let text: Text
    }
    private var request: Request {
        .init(sourceID: sourceID, color: color, dark: colorScheme == .dark, highlights: highlights)
    }

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
                    ScrollView(.horizontal) {
                        Group {
                            if let prepared, prepared.request == request { prepared.text }
                            else { label.foregroundStyle(color) }
                        }
                        .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
        }
        .task(id: request) {
            let request = request, content = content, language = language
            // 与 iOS 共用词法及配色实现，但正则只在后台运行，视图接收完成的 Text。
            let result = await Task.detached(priority: .userInitiated) {
                Prepared(request: request, text: ETCodeSyntaxHighlighter(baseColor: request.color, isOutgoing: false,
                    prefersDarkPalette: request.dark, syntaxHighlightingEnabled: request.highlights,
                    maxHighlightedLength: 12_000).highlightCode(content, language: language))
            }.value
            guard !Task.isCancelled else { return }
            prepared = result
        }
    }
}
