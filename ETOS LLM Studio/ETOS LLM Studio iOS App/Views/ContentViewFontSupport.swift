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

extension Text {
    func etFont(_ font: ETFont?, sampleText: String? = nil) -> some View {
        modifier(ETFontModifier(font, sampleText: sampleText, text: self))
    }
}

enum AppFontAdapter {
    static func adaptedFont(from font: ETFont, sampleText: String? = nil, sizeCategory: ContentSizeCategory = .large) async -> Font {
        await ETFontResolver.shared.font(for: font, sampleText: sampleText, sizeCategory: sizeCategory)
    }
}
