// ============================================================================
// ChatViewMessageInfoSheets.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载聊天页的完整错误响应弹窗与速度曲线组件。
// ============================================================================

import Foundation
import Shared
import SwiftUI
import UIKit

/// 用于承载完整错误响应内容的数据结构
struct FullErrorContentPayload: Identifiable {
    let id = UUID()
    let content: String
}

/// 完整错误响应内容弹窗
struct FullErrorContentSheet: View {
    let payload: FullErrorContentPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(payload.content)
                    .etFont(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(NSLocalizedString("完整响应", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = payload.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}

struct MessageInfoStreamingSpeedChart: View {
    let metrics: MessageResponseMetrics

    private var samples: [MessageResponseMetrics.SpeedSample] {
        let values = metrics.speedSamples ?? []
        return values.sorted { $0.elapsedSecond < $1.elapsedSecond }
    }

    private var currentSpeed: Double {
        max(0, samples.last?.tokenPerSecond ?? metrics.tokenPerSecond ?? 0)
    }

    private var fluctuation: Double? {
        guard samples.count >= 2 else { return nil }
        guard let minSpeed = samples.map(\.tokenPerSecond).min(),
              let maxSpeed = samples.map(\.tokenPerSecond).max() else {
            return nil
        }
        return max(0, maxSpeed - minSpeed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.2f %@", currentSpeed, NSLocalizedString("token/s", comment: "Tokens per second unit")))
                    .etFont(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(NSLocalizedString("每秒采样", comment: "Per-second speed sampling"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let points = normalizedPoints(in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))

                    if points.count >= 2 {
                        smoothedAreaPath(points: points, height: proxy.size.height)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        smoothedLinePath(points: points)
                            .stroke(
                                Color.accentColor.opacity(0.9),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )
                    }

                    if let last = points.last {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .position(last)
                    }
                }
            }
            .frame(height: 96)

            if let fluctuation {
                Text("\(NSLocalizedString("波动", comment: "Speed fluctuation label")) \(String(format: "%.2f %@", fluctuation, NSLocalizedString("token/s", comment: "Tokens per second unit")))")
                    .etFont(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !samples.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let minSecond = Double(samples.first?.elapsedSecond ?? 0)
        let maxSecond = Double(samples.last?.elapsedSecond ?? 0)
        let secondSpan = max(1, maxSecond - minSecond)
        let maxSpeed = max(1, samples.map(\.tokenPerSecond).max() ?? 1)

        return samples.map { sample in
            let xRatio = (Double(sample.elapsedSecond) - minSecond) / secondSpan
            let yRatio = sample.tokenPerSecond / maxSpeed
            return CGPoint(
                x: xRatio * size.width,
                y: (1 - yRatio) * size.height
            )
        }
    }

    private func smoothedLinePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 1 else { return path }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(
                x: (previous.x + current.x) / 2,
                y: (previous.y + current.y) / 2
            )
            path.addQuadCurve(to: midpoint, control: previous)
            if index == points.count - 1 {
                path.addQuadCurve(to: current, control: current)
            }
        }
        return path
    }

    private func smoothedAreaPath(points: [CGPoint], height: CGFloat) -> Path {
        var path = smoothedLinePath(points: points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.addLine(to: CGPoint(x: first.x, y: height))
        path.closeSubpath()
        return path
    }
}
