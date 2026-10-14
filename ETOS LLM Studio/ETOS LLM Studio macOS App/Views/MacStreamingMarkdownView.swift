import ETOSCore
import SwiftUI

struct MacStreamingMarkdownView: View {
    let snapshot: MacStreamingMarkdownSnapshot
    let typography: MacTextTypography
    let fallback: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.blocks) { block in
                // 仅在递归块入口擦除类型，避免流式容器与消息渲染器形成无限 View 类型。
                AnyView(MacMessageTextView(text: block.text, fallback: fallback, typographyOverride: typography))
                    .padding(.top, CGFloat(block.spacing * typography.pointSize))
            }
            if let active = snapshot.active, let text = snapshot.activeText {
                Group {
                    switch active.presentation {
                    case .markdownSource: activeText(text)
                    case .code, .mermaidSource:
                        ScrollView(.horizontal) {
                            activeText(text)
                                .font(typography.codeName.map { Font.custom($0, size: CGFloat(typography.pointSize)) }
                                      ?? Font.system(size: CGFloat(typography.pointSize), design: .monospaced))
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                }
                .id(active.id)
                .padding(.top, CGFloat(active.leadingSpacingEm * typography.pointSize))
            }
        }
    }

    @ViewBuilder private func activeText(_ plain: AttributedString) -> some View {
        if let prepared = snapshot.reveal { MacStreamingRevealingText(prepared: prepared) }
        else { Text(plain) }
    }
}
