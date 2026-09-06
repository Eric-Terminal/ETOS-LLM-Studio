// ============================================================================
// LocalLinuxTerminalPresentation.swift
// ============================================================================
// ETOS LLM Studio
//
// 终端协议在后台被整理为可直接交给 SwiftUI Text 的富文本快照。颜色解析、
// 样式合并与调色板换算不进入 View.body，避免在 iPhone 与 Watch 主线程重复工作。
// ============================================================================

import Foundation
import SwiftUI

public enum LocalLinuxTerminalAppearance: Equatable, Hashable, Sendable {
    case light
    case dark
}

public struct LocalLinuxTerminalPresentation: Equatable, Sendable {
    public static let empty = LocalLinuxTerminalPresentation(
        plainText: "",
        attributedText: AttributedString()
    )

    public let plainText: String
    public let attributedText: AttributedString

    public init(plainText: String, attributedText: AttributedString) {
        self.plainText = plainText
        self.attributedText = attributedText
    }
}

enum LocalLinuxTerminalIdentity {
    static let programName = "ETOS-LLM-Studio"
    static let programVersion: String = {
        let bundle = Bundle.main
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
    }()

    static var versionReport: Data {
        Data("\u{1B}P>|\(programName)(\(programVersion))\u{1B}\\".utf8)
    }
}

enum LocalLinuxTerminalColor: Equatable, Sendable {
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)

    var swiftUIColor: Color {
        let components = rgbComponents
        return Color(
            red: Double(components.red) / 255,
            green: Double(components.green) / 255,
            blue: Double(components.blue) / 255
        )
    }

    var xtermColorReport: String {
        let components = rgbComponents
        return String(
            format: "rgb:%04x/%04x/%04x",
            UInt16(components.red) * 257,
            UInt16(components.green) * 257,
            UInt16(components.blue) * 257
        )
    }

    private var rgbComponents: (red: UInt8, green: UInt8, blue: UInt8) {
        switch self {
        case .rgb(let red, let green, let blue):
            return (red, green, blue)
        case .indexed(let index):
            return Self.paletteColor(index)
        }
    }

    private static func paletteColor(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
        let base: [(UInt8, UInt8, UInt8)] = [
            (0x00, 0x00, 0x00), (0xCD, 0x00, 0x00),
            (0x00, 0xCD, 0x00), (0xCD, 0xCD, 0x00),
            (0x00, 0x00, 0xEE), (0xCD, 0x00, 0xCD),
            (0x00, 0xCD, 0xCD), (0xE5, 0xE5, 0xE5),
            (0x7F, 0x7F, 0x7F), (0xFF, 0x00, 0x00),
            (0x00, 0xFF, 0x00), (0xFF, 0xFF, 0x00),
            (0x5C, 0x5C, 0xFF), (0xFF, 0x00, 0xFF),
            (0x00, 0xFF, 0xFF), (0xFF, 0xFF, 0xFF)
        ]
        if index < 16 { return base[Int(index)] }
        if index < 232 {
            let cube = Int(index) - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return (
                levels[cube / 36],
                levels[(cube / 6) % 6],
                levels[cube % 6]
            )
        }
        let gray = UInt8(8 + (Int(index) - 232) * 10)
        return (gray, gray, gray)
    }
}

struct LocalLinuxTerminalStyle: Equatable, Sendable {
    static let `default` = LocalLinuxTerminalStyle()

    var foreground: LocalLinuxTerminalColor?
    var background: LocalLinuxTerminalColor?
    var isBold = false
    var isFaint = false
    var isItalic = false
    var isUnderlined = false
    var isBlinking = false
    var isInverse = false
    var isConcealed = false
    var isStruckThrough = false

    var keepsTrailingBlankVisible: Bool {
        background != nil || isInverse || isUnderlined || isStruckThrough
    }

    func attributedString(
        _ text: String,
        appearance: LocalLinuxTerminalAppearance
    ) -> AttributedString {
        var attributed = AttributedString(text)
        guard !text.isEmpty else { return attributed }
        let range = attributed.startIndex..<attributed.endIndex
        let resolved = resolvedColors(for: appearance)
        attributed[range].foregroundColor = isConcealed
            ? Color.clear
            : resolved.foreground.opacity(isFaint ? 0.55 : 1)
        if let background = resolved.background {
            attributed[range].backgroundColor = background
        }
        var intent: InlinePresentationIntent = []
        if isBold { intent.insert(.stronglyEmphasized) }
        if isItalic { intent.insert(.emphasized) }
        if !intent.isEmpty { attributed[range].inlinePresentationIntent = intent }
        if isUnderlined { attributed[range].underlineStyle = .single }
        if isStruckThrough { attributed[range].strikethroughStyle = .single }
        return attributed
    }

    private func resolvedColors(
        for appearance: LocalLinuxTerminalAppearance
    ) -> (foreground: Color, background: Color?) {
        let defaultForeground: Color
        let defaultBackground: Color
        switch appearance {
        case .light:
            defaultForeground = Color(red: 0.10, green: 0.10, blue: 0.10)
            defaultBackground = .white
        case .dark:
            defaultForeground = Color(red: 0.90, green: 0.90, blue: 0.90)
            defaultBackground = .black
        }
        let foreground = foreground?.swiftUIColor ?? defaultForeground
        let background = background?.swiftUIColor
        if isInverse {
            return (background ?? defaultBackground, foreground)
        }
        return (foreground, background)
    }
}

struct LocalLinuxTerminalLinePresentation: Equatable, Sendable {
    let plainText: String
    let lightAttributedText: AttributedString
    let darkAttributedText: AttributedString

    var isEmpty: Bool { plainText.isEmpty }

    func attributedText(for appearance: LocalLinuxTerminalAppearance) -> AttributedString {
        switch appearance {
        case .light:
            return lightAttributedText
        case .dark:
            return darkAttributedText
        }
    }
}
