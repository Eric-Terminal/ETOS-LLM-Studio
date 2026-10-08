import AppKit
import ETOSCore
import SwiftUI

struct MacMessageBubbleBackground: View {
    let outgoing: Bool
    let isError: Bool
    let palette: MacChatPalette
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !configuration.enableNoBubbleUI || outgoing || isError {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            let color = isError ? Color.red.opacity(0.12) : (outgoing ? palette.userBubble : palette.assistantBubble ?? Color(nsColor: .controlBackgroundColor))
            if configuration.enableLiquidGlass && !reduceTransparency {
                shape.fill(color.opacity(configuration.enableBackground ? 0.75 : 1))
                    .glassEffect(.clear, in: shape)
            } else {
                shape.fill(color.opacity(configuration.enableBackground && !reduceTransparency ? 0.85 : 1))
            }
        }
    }
}

private struct MacChatTextPaletteKey: EnvironmentKey {
    static let defaultValue = MacChatTextPalette.automatic
}

extension EnvironmentValues {
    var macChatTextPalette: MacChatTextPalette {
        get { self[MacChatTextPaletteKey.self] }
        set { self[MacChatTextPaletteKey.self] = newValue }
    }
}

/// 输入区域使用原生玻璃底层；减少透明度时保留系统实色以保证可读性。
struct MacComposerAppearance: ViewModifier {
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if configuration.enableLiquidGlass && !reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor).opacity(configuration.liquidGlassTintOpacity))
                .glassEffect(.clear, in: Rectangle())
        } else { content.background(Color(nsColor: .windowBackgroundColor)) }
    }
}
