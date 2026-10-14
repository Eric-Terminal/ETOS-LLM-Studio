import AppKit
import ETOSCore
import SwiftUI

/// 字体覆盖检查和四个语义槽位在后台准备，视图只消费不可变结果。
struct MacTextTypography: @unchecked Sendable {
    let body: Font
    let bodyName: String?
    let emphasisName: String?
    let strongName: String?
    let codeName: String?
    let pointSize: Double
    let lineSpacing: Double
    static let baseSize = Double(NSFont.systemFontSize)
    static let system = MacTextTypography(body: .system(size: CGFloat(baseSize)), bodyName: nil, emphasisName: nil,
                                         strongName: nil, codeName: nil, pointSize: baseSize, lineSpacing: 0)

    static func prepare(_ source: String, lineSpacing: Double) async -> MacTextTypography {
        let body = await ETFontResolver.shared.font(for: .system(size: CGFloat(baseSize)), sampleText: source)
        let scale = FontLibrary.customFontScale
        return MacTextTypography(body: body,
            bodyName: FontLibrary.resolvePostScriptName(for: .body, sampleText: source),
            emphasisName: FontLibrary.resolvePostScriptName(for: .emphasis, sampleText: source),
            strongName: FontLibrary.resolvePostScriptName(for: .strong, sampleText: source),
            codeName: FontLibrary.resolvePostScriptName(for: .code, sampleText: source), pointSize: baseSize * scale,
            lineSpacing: FontLibrary.lineSpacingPoints(basePointSize: baseSize, lineSpacingEm: lineSpacing,
                fontScale: scale, isCustomFontEnabled: FontLibrary.isCustomFontEnabled, fallbackLineSpacingEm: FontLibrary.defaultIOSLineSpacingEm))
    }
}
