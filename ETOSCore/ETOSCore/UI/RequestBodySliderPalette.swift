import SwiftUI

/// iOS 与 Mac 共用参数配色；解析控制定义应在展示数据准备阶段完成。
public enum RequestBodySliderPalette: Hashable, Sendable {
    case structured
    case temperature
    case custom(start: RequestBodySliderColorComponents, end: RequestBodySliderColorComponents)

    public static func defaultPalette(for control: ModelRequestBodyControl) -> RequestBodySliderPalette {
        control.options.contains { $0.payload.keys.contains("temperature") } ? .temperature : .structured
    }

    public static func resolved(for control: ModelRequestBodyControl) -> RequestBodySliderPalette {
        let fallback = defaultPalette(for: control)
        guard control.sliderStartColorHex != nil || control.sliderEndColorHex != nil else { return fallback }
        let fallbackStart = fallback.color(at: 0), fallbackEnd = fallback.color(at: 1)
        let startColor = control.sliderStartColorHex.map { ChatAppearanceColorCodec.color(from: $0, fallback: fallbackStart) } ?? fallbackStart
        let endColor = control.sliderEndColorHex.map { ChatAppearanceColorCodec.color(from: $0, fallback: fallbackEnd) } ?? fallbackEnd
        guard let start = RequestBodySliderColorComponents(color: startColor),
              let end = RequestBodySliderColorComponents(color: endColor) else { return fallback }
        return .custom(start: start, end: end)
    }

    public var gradient: LinearGradient {
        LinearGradient(colors: [color(at: 0), color(at: 0.34), color(at: 0.68), color(at: 1)], startPoint: .leading, endPoint: .trailing)
    }

    public func color(at position: Double) -> Color {
        let position = position.isFinite ? min(max(position, 0), 1) : 0
        switch self {
        case .structured: return Color(hue: 0.58 + position * 0.29, saturation: 0.72, brightness: 0.94)
        case .temperature:
            // 蓝、紫、红的色相路线保留温度语义，不穿过绿色。
            return Color(hue: 0.62 + position * 0.38, saturation: 0.78, brightness: 0.96)
        case .custom(let start, let end): return start.interpolated(to: end, at: position).color
        }
    }
}
