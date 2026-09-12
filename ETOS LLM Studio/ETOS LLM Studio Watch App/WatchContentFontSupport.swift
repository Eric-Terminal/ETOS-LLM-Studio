import SwiftUI
import ETOSCore

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

    static func scaledSystemPointSize(from font: ETFont) -> CGFloat {
        font.basePointSize * CGFloat(FontLibrary.customFontScale)
    }
}
