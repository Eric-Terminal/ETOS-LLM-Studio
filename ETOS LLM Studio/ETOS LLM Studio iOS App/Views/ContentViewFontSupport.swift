import SwiftUI
import ETOSCore

extension Notification.Name {
    static let requestSwitchToChatTab = Notification.Name("ios.requestSwitchToChatTab")
}

extension View {
    func etFont(_ font: ETFont?, sampleText: String? = nil) -> some View {
        modifier(ETFontModifier(font, sampleText: sampleText))
    }
}

enum AppFontAdapter {
    static func adaptedFont(from font: ETFont, sampleText: String? = nil) async -> Font {
        await ETFontResolver.shared.font(for: font, sampleText: sampleText)
    }
}
