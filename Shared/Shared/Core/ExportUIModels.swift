// ============================================================================
// ExportUIModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义导出数据结构、轻量 UI 状态枚举与聊天外观颜色编解码工具。
// ============================================================================

import Foundation
import SwiftUI
import CoreGraphics

// MARK: - 导出相关模型 (待审阅)
// 注意: 以下导出模型可能可以被简化的或由ChatMessage直接替代

/// 用于导出的聊天消息数据结构
public struct ExportableChatMessage: Codable {
    public var role: String
    public var content: String
    public var reasoning: String?

    public init(role: String, content: String, reasoning: String?) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
    }
}

/// 用于导出提示词的结构
public struct ExportPrompts: Codable {
    public let globalSystemPrompt: String?
    public let topicPrompt: String?
    public let enhancedPrompt: String?

    public init(globalSystemPrompt: String?, topicPrompt: String?, enhancedPrompt: String?) {
        self.globalSystemPrompt = globalSystemPrompt
        self.topicPrompt = topicPrompt
        self.enhancedPrompt = enhancedPrompt
    }
}

/// 完整的导出数据结构
public struct FullExportData: Codable {
    public let prompts: ExportPrompts
    public let history: [ExportableChatMessage]

    public init(prompts: ExportPrompts, history: [ExportableChatMessage]) {
        self.prompts = prompts
        self.history = history
    }
}

// MARK: - UI状态模型 (待审阅)
// 注意: 以下模型属于UI状态，更适合放在视图相关的代码文件中

/// 用于管理所有可能弹出的 Sheet 视图的枚举
public enum ActiveSheet: Identifiable, Equatable {
    case settings
    case editMessage

    public var id: Int {
        switch self {
        case .settings: return 1
        case .editMessage: return 2
        }
    }
}

// MARK: - 聊天气泡颜色偏好工具

/// 聊天气泡颜色偏好编解码工具。
/// - 统一处理十六进制 RGBA（RRGGBBAA）与 `Color` 之间的转换。
public enum ChatAppearanceColorCodec {
    /// 将十六进制颜色字符串解析为 `Color`。
    /// - Parameters:
    ///   - hexRGBA: 支持 `RRGGBB`、`RRGGBBAA`，也支持前缀 `#`。
    ///   - fallback: 解析失败时的回退颜色。
    public static func color(from hexRGBA: String, fallback: Color) -> Color {
        let sanitized = hexRGBA
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()

        let normalized: String
        if sanitized.count == 6 {
            normalized = sanitized + "FF"
        } else if sanitized.count == 8 {
            normalized = sanitized
        } else {
            return fallback
        }

        guard let value = UInt64(normalized, radix: 16) else {
            return fallback
        }

        let red = Double((value >> 24) & 0xFF) / 255.0
        let green = Double((value >> 16) & 0xFF) / 255.0
        let blue = Double((value >> 8) & 0xFF) / 255.0
        let alpha = Double(value & 0xFF) / 255.0

        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// 将 `Color` 编码为十六进制 RGBA 字符串（`RRGGBBAA`）。
    public static func hexRGBA(from color: Color) -> String? {
        guard let rgba = rgbaComponents(from: color) else { return nil }
        let red = UInt8(clampedToByte(rgba.red * 255.0))
        let green = UInt8(clampedToByte(rgba.green * 255.0))
        let blue = UInt8(clampedToByte(rgba.blue * 255.0))
        let alpha = UInt8(clampedToByte(rgba.alpha * 255.0))
        return String(format: "%02X%02X%02X%02X", red, green, blue, alpha)
    }

    /// 将颜色按给定比例变暗（仅处理 RGB，保留 Alpha）。
    /// - Parameter factor: 取值区间建议 0~1，越小越暗。
    public static func darkened(_ color: Color, factor: Double) -> Color {
        guard let rgba = rgbaComponents(from: color) else { return color }
        let scale = min(max(factor, 0), 1)
        return Color(
            .sRGB,
            red: rgba.red * scale,
            green: rgba.green * scale,
            blue: rgba.blue * scale,
            opacity: rgba.alpha
        )
    }

    /// 替换颜色透明度并保留 RGB 分量。
    public static func replacingAlpha(of color: Color, with alpha: Double) -> Color {
        let adjustedAlpha = min(max(alpha, 0), 1)
        guard let rgba = rgbaComponents(from: color) else {
            return color.opacity(adjustedAlpha)
        }
        return Color(
            .sRGB,
            red: rgba.red,
            green: rgba.green,
            blue: rgba.blue,
            opacity: adjustedAlpha
        )
    }

    /// 提取颜色 RGBA 分量（sRGB）。
    public static func rgbaComponents(from color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let cgColor = color.cgColor else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let converted = cgColor.converted(to: colorSpace, intent: .defaultIntent, options: nil) ?? cgColor
        guard let components = converted.components, !components.isEmpty else { return nil }

        switch components.count {
        case 4:
            return (
                red: clamp01(components[0]),
                green: clamp01(components[1]),
                blue: clamp01(components[2]),
                alpha: clamp01(components[3])
            )
        case 3:
            return (
                red: clamp01(components[0]),
                green: clamp01(components[1]),
                blue: clamp01(components[2]),
                alpha: 1
            )
        case 2:
            let gray = clamp01(components[0])
            return (
                red: gray,
                green: gray,
                blue: gray,
                alpha: clamp01(components[1])
            )
        default:
            return nil
        }
    }

    private static func clamp01(_ value: CGFloat) -> Double {
        min(max(Double(value), 0), 1)
    }

    private static func clampedToByte(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), 255)
    }
}
