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

/// 输入框与消息共享阅读宽度；使用独立的系统材质承载输入，避免整条窗口底栏抢占注意力。
struct MacComposerAppearance: ViewModifier {
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if configuration.enableLiquidGlass && !reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor).opacity(configuration.liquidGlassTintOpacity), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        }
    }
}
