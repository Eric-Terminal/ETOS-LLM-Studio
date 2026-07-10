// ============================================================================
// ChatTranscriptImageRenderModels.swift
// ============================================================================
// 聊天长图导出的外观快照与内部排版模型。
// ============================================================================

import CoreGraphics
import Foundation

public struct ChatTranscriptImageStyle: Sendable {
    public enum BackgroundContentMode: String, Sendable {
        case fill
        case fit
    }

    public var prefersDarkAppearance: Bool
    public var backgroundMediaURL: URL?
    public var backgroundOpacity: Double
    public var backgroundBlurRadius: Double
    public var backgroundContentMode: BackgroundContentMode
    public var usesCustomBackground: Bool
    public var userBubbleHex: String?
    public var assistantBubbleHex: String?
    public var userTextHex: String?
    public var assistantTextHex: String?
    public var usesNoBubbleStyle: Bool
    public var subtitle: String?
    public var inputPlaceholder: String
    public var untitledConversationName: String

    public init(
        prefersDarkAppearance: Bool = false,
        backgroundMediaURL: URL? = nil,
        backgroundOpacity: Double = 1,
        backgroundBlurRadius: Double = 0,
        backgroundContentMode: BackgroundContentMode = .fill,
        usesCustomBackground: Bool = false,
        userBubbleHex: String? = nil,
        assistantBubbleHex: String? = nil,
        userTextHex: String? = nil,
        assistantTextHex: String? = nil,
        usesNoBubbleStyle: Bool = false,
        subtitle: String? = nil,
        inputPlaceholder: String = NSLocalizedString("Message", comment: "聊天长图输入框占位文本"),
        untitledConversationName: String = NSLocalizedString("新的对话", comment: "聊天长图未命名会话标题")
    ) {
        self.prefersDarkAppearance = prefersDarkAppearance
        self.backgroundMediaURL = backgroundMediaURL
        self.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        self.backgroundBlurRadius = max(0, backgroundBlurRadius)
        self.backgroundContentMode = backgroundContentMode
        self.usesCustomBackground = usesCustomBackground
        self.userBubbleHex = userBubbleHex
        self.assistantBubbleHex = assistantBubbleHex
        self.userTextHex = userTextHex
        self.assistantTextHex = assistantTextHex
        self.usesNoBubbleStyle = usesNoBubbleStyle
        self.subtitle = subtitle
        self.inputPlaceholder = inputPlaceholder
        self.untitledConversationName = untitledConversationName
    }
}

struct MessageLayout {
    let message: ChatMessage
    let content: String
    let reasoning: String
    let tools: [ToolSummary]
    let files: [String]
    let audioFileName: String?
    let images: [ImageAttachmentLayout]
    let contentHeight: CGFloat
    let reasoningHeight: CGFloat
    let toolDetailHeights: [CGFloat]
    let size: CGSize
    let isOutgoing: Bool
    let isError: Bool
    let usesNoBubble: Bool
}

struct PositionedMessage {
    let layout: MessageLayout
    let rect: CGRect
}

struct ImageAttachmentLayout {
    let fileName: String
    let image: CGImage?
    let size: CGSize
}

struct ToolSummary {
    let name: String
    let detail: String
}

struct FontSpec {
    let size: CGFloat
    let isBold: Bool

    init(size: CGFloat, isBold: Bool = false) {
        self.size = size
        self.isBold = isBold
    }
}

struct Theme {
    let baseBackground: CGColor
    let backgroundGradientStart: CGColor
    let backgroundGradientEnd: CGColor
    let patternColor: CGColor
    let chrome: CGColor
    let controlFill: CGColor
    let chromeForeground: CGColor
    let chromeSecondary: CGColor
    let actionFill: CGColor
    let userBubbleStart: CGColor
    let userBubbleEnd: CGColor
    let assistantBubble: CGColor
    let userText: CGColor
    let assistantText: CGColor
    let errorBubble: CGColor
    let errorText: CGColor
    let shadow: CGColor

    init(style: ChatTranscriptImageStyle) {
        let isDark = style.prefersDarkAppearance
        baseBackground = isDark ? Self.color(0.08, 0.10, 0.12) : Self.color(0.88, 0.92, 0.95)
        backgroundGradientStart = isDark ? Self.color(0.10, 0.12, 0.15) : Self.color(0.85, 0.90, 0.92)
        backgroundGradientEnd = isDark ? Self.color(0.08, 0.10, 0.12) : Self.color(0.88, 0.92, 0.95)
        patternColor = isDark ? Self.color(1, 1, 1, alpha: 0.035) : Self.color(0.2, 0.25, 0.3, alpha: 0.055)
        chrome = isDark ? Self.color(0.08, 0.09, 0.11, alpha: 0.90) : Self.color(1, 1, 1, alpha: 0.88)
        controlFill = isDark ? Self.color(1, 1, 1, alpha: 0.10) : Self.color(1, 1, 1, alpha: 0.72)
        chromeForeground = isDark ? Self.color(0.96, 0.96, 0.98) : Self.color(0.10, 0.11, 0.13)
        chromeSecondary = isDark ? Self.color(0.72, 0.73, 0.77) : Self.color(0.38, 0.40, 0.44)
        actionFill = Self.color(0.24, 0.56, 0.95)

        let fallbackUserStart = Self.color(0.24, 0.56, 0.95)
        let customUser = style.userBubbleHex.flatMap(Self.parseHex) ?? fallbackUserStart
        userBubbleStart = customUser.copy(alpha: customUser.alpha * (style.usesCustomBackground ? 0.85 : 1)) ?? customUser
        userBubbleEnd = Self.darkened(userBubbleStart, factor: 0.86)

        let fallbackAssistant = isDark ? Self.color(0.16, 0.17, 0.20) : Self.color(1, 1, 1)
        let customAssistant = style.assistantBubbleHex.flatMap(Self.parseHex) ?? fallbackAssistant
        assistantBubble = customAssistant.copy(alpha: customAssistant.alpha * (style.usesCustomBackground ? 0.75 : 1)) ?? customAssistant
        userText = style.userTextHex.flatMap(Self.parseHex) ?? Self.color(1, 1, 1)
        assistantText = style.assistantTextHex.flatMap(Self.parseHex)
            ?? (isDark ? Self.color(0.96, 0.96, 0.98) : Self.color(0.11, 0.11, 0.12))
        errorBubble = Self.color(0.82, 0.16, 0.18, alpha: style.usesCustomBackground ? 0.82 : 0.92)
        errorText = Self.color(1, 1, 1)
        shadow = Self.color(0, 0, 0, alpha: isDark ? 0.24 : 0.12)
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func parseHex(_ raw: String) -> CGColor? {
        let sanitized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let normalized = sanitized.count == 6 ? sanitized + "FF" : sanitized
        guard normalized.count == 8, let value = UInt64(normalized, radix: 16) else { return nil }
        return color(
            CGFloat((value >> 24) & 0xFF) / 255,
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            alpha: CGFloat(value & 0xFF) / 255
        )
    }

    private static func darkened(_ color: CGColor, factor: CGFloat) -> CGColor {
        guard let components = color.components else { return color }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if components.count >= 4 {
            red = components[0]
            green = components[1]
            blue = components[2]
            alpha = components[3]
        } else if components.count == 2 {
            red = components[0]
            green = components[0]
            blue = components[0]
            alpha = components[1]
        } else {
            return color
        }
        return self.color(red * factor, green * factor, blue * factor, alpha: alpha)
    }
}

extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}
