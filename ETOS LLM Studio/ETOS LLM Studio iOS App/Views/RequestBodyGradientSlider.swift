// ============================================================================
// RequestBodyGradientSlider.swift
// ============================================================================
// ETOS LLM Studio
//
// 为结构化选项提供随进度揭示色谱的横向滑块，并保留锚点与辅助功能调整。
// ============================================================================

import SwiftUI
import UIKit

enum RequestBodySliderPalette {
    case structured
    case temperature

    var gradient: LinearGradient {
        LinearGradient(
            colors: [
                color(at: 0),
                color(at: 0.34),
                color(at: 0.68),
                color(at: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    func color(at position: Double) -> Color {
        let normalizedPosition = min(max(position, 0), 1)
        switch self {
        case .structured:
            return Color(
                hue: 0.58 + normalizedPosition * 0.29,
                saturation: 0.72,
                brightness: 0.94
            )
        case .temperature:
            // 沿蓝、紫、红方向过渡，避免冷热语义中间出现无关的绿色。
            return Color(
                hue: 0.62 + normalizedPosition * 0.38,
                saturation: 0.78,
                brightness: 0.96
            )
        }
    }
}

struct RequestBodyGradientSlider: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var thumbDiameter: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var trackHeight: CGFloat = 8

    @Binding var value: Double
    var palette: RequestBodySliderPalette = .structured
    let anchorCount: Int
    let adjustmentStep: Double
    let accessibilityLabel: String
    let accessibilityValue: String
    let onEditingChanged: (Bool) -> Void

    @State private var isEditing = false

    var body: some View {
        GeometryReader { geometry in
            slider(size: geometry.size)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geometry.size.width))
        }
        .frame(height: thumbDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAdjustableAction { direction in
            let delta: Double
            switch direction {
            case .increment:
                delta = adjustmentStep
            case .decrement:
                delta = -adjustmentStep
            @unknown default:
                return
            }
            onEditingChanged(true)
            value = normalized(value + delta)
            onEditingChanged(false)
        }
    }

    private func slider(size: CGSize) -> some View {
        let normalizedValue = normalized(value)
        let travelWidth = max(size.width - thumbDiameter, 1)
        let thumbCenterX = thumbDiameter / 2 + travelWidth * normalizedValue
        let fillWidth = size.width * normalizedValue

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: trackHeight)

            palette.gradient
                .frame(height: trackHeight)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: fillWidth)
                }
                .clipShape(Capsule())

            anchorMarks(size: size, travelWidth: travelWidth, normalizedValue: normalizedValue)

            thumb(at: thumbCenterX, color: palette.color(at: normalizedValue))
        }
        .frame(maxHeight: .infinity)
    }

    private func anchorMarks(
        size: CGSize,
        travelWidth: CGFloat,
        normalizedValue: Double
    ) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0..<anchorCount, id: \.self) { index in
                let anchorPosition = anchorCount > 1
                    ? Double(index) / Double(anchorCount - 1)
                    : 0
                Circle()
                    .fill(anchorPosition <= normalizedValue
                        ? Color.white.opacity(0.8)
                        : Color.secondary.opacity(0.48))
                    .frame(width: 4, height: 4)
                    .position(
                        x: thumbDiameter / 2 + travelWidth * anchorPosition,
                        y: size.height / 2
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func thumb(at xPosition: CGFloat, color: Color) -> some View {
        Group {
            if reduceTransparency {
                Circle().fill(Color(uiColor: .systemBackground))
            } else {
                Circle().fill(.regularMaterial)
            }
        }
        .frame(width: thumbDiameter, height: thumbDiameter)
        .overlay {
            Circle()
                .fill(color.opacity(0.16))
        }
        .overlay {
            Circle()
                .stroke(color.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: color.opacity(0.24), radius: 4, y: 2)
        .position(x: xPosition, y: thumbDiameter / 2)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !isEditing {
                    isEditing = true
                    onEditingChanged(true)
                }
                updateValue(for: drag.location.x, width: width)
            }
            .onEnded { drag in
                updateValue(for: drag.location.x, width: width)
                isEditing = false
                onEditingChanged(false)
            }
    }

    private func updateValue(for xPosition: CGFloat, width: CGFloat) {
        let travelWidth = max(width - thumbDiameter, 1)
        value = normalized(Double((xPosition - thumbDiameter / 2) / travelWidth))
    }

    private func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
