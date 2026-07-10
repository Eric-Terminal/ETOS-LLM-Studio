// ============================================================================
// RequestBodySliderColorSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供结构化控制滑块双色端点的 sRGB 插值数据。
// ============================================================================

import SwiftUI

public struct RequestBodySliderColorComponents: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.normalized(red)
        self.green = Self.normalized(green)
        self.blue = Self.normalized(blue)
        self.alpha = Self.normalized(alpha)
    }

    public init?(color: Color) {
        guard let components = ChatAppearanceColorCodec.rgbaComponents(from: color) else {
            return nil
        }
        self.init(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }

    public var color: Color {
        Color(
            .sRGB,
            red: red,
            green: green,
            blue: blue,
            opacity: alpha
        )
    }

    public func interpolated(
        to target: RequestBodySliderColorComponents,
        at position: Double
    ) -> RequestBodySliderColorComponents {
        let progress = Self.normalized(position)
        return RequestBodySliderColorComponents(
            red: red + (target.red - red) * progress,
            green: green + (target.green - green) * progress,
            blue: blue + (target.blue - blue) * progress,
            alpha: alpha + (target.alpha - alpha) * progress
        )
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
