import ETOSCore
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@Suite("手表字体离屏准备", .serialized)
@MainActor
struct WatchFontPreparationTests {
    @Test("文字重载在导出中保留用户倍率和实际 Dynamic Type")
    func exportsPreparedDynamicType() async throws {
        let enabled = FontLibrary.isCustomFontEnabled
        let scope = FontLibrary.fallbackScope
        let scale = FontLibrary.customFontScale
        defer {
            FontLibrary.updateRuntimeSettings(isCustomFontEnabled: enabled, fallbackScope: scope, customFontScale: scale)
        }
        FontLibrary.updateRuntimeSettings(isCustomFontEnabled: false, fallbackScope: .segment, customFontScale: 1.5)
        let regular = try await measurePreparedText(sizeCategory: .large)
        let enlarged = try await measurePreparedText(sizeCategory: .extraExtraExtraLarge)
        #expect(enlarged.height > regular.height)
        #expect(enlarged.width > regular.width)
    }

    private func measurePreparedText(sizeCategory: ContentSizeCategory) async throws -> CGSize {
        let preparation = ETFontExportPreparation()
        let renderer = ImageRenderer(content: Text(verbatim: "混排 Watch")
            .etFont(.body)
            .environment(\.sizeCategory, sizeCategory)
            .environment(\.etFontExportPreparation, preparation))
        renderer.render { _, _ in }
        #expect(try await preparation.preparePendingFonts())
        var measured = CGSize.zero
        renderer.render { size, _ in measured = size }
        #expect(try await !preparation.preparePendingFonts())
        #expect(measured.height > 0)
        return measured
    }
}
