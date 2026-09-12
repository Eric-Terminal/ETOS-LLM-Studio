import SwiftUI
import ETOSCore

extension View {
    func etFont(_ font: ETFont?, sampleText: String? = nil) -> some View {
        modifier(ETFontModifier(font, sampleText: sampleText))
    }
}

enum AppFontAdapter {
    static func adaptedFont(from font: ETFont, sampleText: String? = nil) async -> Font {
        await ETFontResolver.shared.font(for: font, sampleText: sampleText)
    }

    static func scaledSystemPointSize(from font: ETFont) -> CGFloat {
        font.basePointSize * CGFloat(FontLibrary.customFontScale)
    }
}
