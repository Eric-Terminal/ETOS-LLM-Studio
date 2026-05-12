// ============================================================================
// ChatViewMessageInfoSheets.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载聊天页的消息信息、完整错误响应与速度曲线弹窗。
// ============================================================================

import Foundation
import Shared
import SwiftUI
import UIKit

/// 用于承载消息信息弹窗的数据结构，避免直接暴露 ChatMessage 本身。
struct MessageInfoPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let displayIndex: Int
    let totalCount: Int
}

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

/// 消息详情弹窗，展示消息的唯一标识与位置索引。
struct MessageInfoSheet: View {
    let payload: MessageInfoPayload
    let onJumpToMessage: (Int) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var jumpInput: String = ""
    @State private var jumpError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基础信息", comment: "")) {
                    LabeledContent(NSLocalizedString("角色", comment: "")) {
                        Text(roleDescription(payload.message.role))
                    }
                    LabeledContent(NSLocalizedString("列表位置", comment: "")) {
                        Text(
                            String(
                                format: NSLocalizedString("第 %d / %d 条", comment: ""),
                                payload.displayIndex,
                                payload.totalCount
                            )
                        )
                    }

                }

                Section(NSLocalizedString("快速定位", comment: "Quick message jump section title")) {
                    TextField(
                        String(
                            format: NSLocalizedString("输入消息序号（1-%d）", comment: "Message index input placeholder"),
                            payload.totalCount
                        ),
                        text: $jumpInput
                    )
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        submitJump()
                    } label: {
                        Label(NSLocalizedString("跳转到该条消息", comment: "Jump to message button title"), systemImage: "location")
                    }
                    .buttonStyle(.borderedProminent)

                    if let jumpError, !jumpError.isEmpty {
                        Text(jumpError)
                            .etFont(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section(NSLocalizedString("唯一标识", comment: "")) {
                    Text(payload.message.id.uuidString)
                        .etFont(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                if let usage = payload.message.tokenUsage, usage.hasData {
                    Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                        if let prompt = usage.promptTokens {
                            LabeledContent(NSLocalizedString("发送 Tokens", comment: "Prompt tokens label")) {
                                Text("\(prompt)")
                            }
                        }
                        if let completion = usage.completionTokens {
                            LabeledContent(NSLocalizedString("接收 Tokens", comment: "Completion tokens label")) {
                                Text("\(completion)")
                            }
                        }
                        if let thinking = usage.thinkingTokens {
                            LabeledContent(NSLocalizedString("思考 Tokens", comment: "Thinking tokens label")) {
                                Text("\(thinking)")
                            }
                        }
                        if let cacheWrite = usage.cacheWriteTokens {
                            LabeledContent(NSLocalizedString("缓存写入 Tokens", comment: "Cache write tokens label")) {
                                Text("\(cacheWrite)")
                            }
                        }
                        if let cacheRead = usage.cacheReadTokens {
                            LabeledContent(NSLocalizedString("缓存读取 Tokens", comment: "Cache read tokens label")) {
                                Text("\(cacheRead)")
                            }
                        }
                        if let total = usage.totalTokens, (usage.promptTokens != total || usage.completionTokens != total) {
                            LabeledContent(NSLocalizedString("总计", comment: "Total tokens label")) {
                                Text("\(total)")
                            }
                        } else if let totalOnly = usage.totalTokens, usage.promptTokens == nil && usage.completionTokens == nil {
                            LabeledContent(NSLocalizedString("总计", comment: "Total tokens label")) {
                                Text("\(totalOnly)")
                            }
                        }
                    }
                } else if let metrics = payload.message.responseMetrics, metrics.isTokenPerSecondEstimated {
                    Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                        Text(NSLocalizedString("当前响应未返回官方 token 用量（仅有估算速度）。", comment: "No official token usage returned hint"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let metrics = payload.message.responseMetrics,
                   metrics.timeToFirstToken != nil
                    || metrics.totalResponseDuration != nil
                    || metrics.reasoningDuration != nil
                    || metrics.completionTokensForSpeed != nil
                    || metrics.tokenPerSecond != nil {
                    Section(NSLocalizedString("响应测速", comment: "Response speed metrics section title")) {
                        if let firstToken = metrics.timeToFirstToken {
                            LabeledContent(NSLocalizedString("首字时间", comment: "Time to first token")) {
                                Text(formatDuration(firstToken))
                            }
                        }
                        if let totalDuration = metrics.totalResponseDuration {
                            LabeledContent(NSLocalizedString("总回复时间", comment: "Total response time")) {
                                Text(formatDuration(totalDuration))
                            }
                        }
                        if let reasoningDuration = metrics.reasoningDuration {
                            LabeledContent(NSLocalizedString("思考耗时", comment: "Reasoning duration")) {
                                Text(formatDuration(reasoningDuration))
                            }
                        }
                        if let completionTokens = metrics.completionTokensForSpeed {
                            LabeledContent(NSLocalizedString("测速 Tokens", comment: "Tokens used for speed calculation")) {
                                Text("\(completionTokens)")
                            }
                        }
                        if let speed = metrics.tokenPerSecond {
                            LabeledContent(NSLocalizedString("响应速度", comment: "Response speed")) {
                                Text(formatSpeed(speed, estimated: metrics.isTokenPerSecondEstimated))
                            }
                        }
                    }
                }

                if let metrics = payload.message.responseMetrics,
                   let samples = metrics.speedSamples,
                   !samples.isEmpty {
                    Section(NSLocalizedString("流式速度曲线", comment: "Streaming speed chart title")) {
                        MessageInfoStreamingSpeedChart(metrics: metrics)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("消息信息", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
        }
    }

    /// 将消息角色转换为易读的中文描述
    private func roleDescription(_ role: MessageRole) -> String {
        switch role {
        case .system:
            return NSLocalizedString("系统", comment: "")
        case .user:
            return NSLocalizedString("用户", comment: "")
        case .assistant:
            return NSLocalizedString("助手", comment: "")
        case .tool:
            return NSLocalizedString("工具", comment: "")
        case .error:
            return NSLocalizedString("错误", comment: "")
        @unknown default:
            return NSLocalizedString("未知", comment: "")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let clamped = max(0, duration)
        return String(format: "%.2fs", clamped)
    }

    private func formatSpeed(_ speed: Double, estimated: Bool) -> String {
        let base = String(format: "%.2f %@", max(0, speed), NSLocalizedString("token/s", comment: "Tokens per second unit"))
        if estimated {
            return "\(base) (\(NSLocalizedString("估算", comment: "Estimated")))"
        }
        return base
    }

    private func submitJump() {
        let trimmed = jumpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayIndex = Int(trimmed) else {
            jumpError = NSLocalizedString("请输入有效的序号。", comment: "Invalid message index hint")
            return
        }

        guard displayIndex >= 1 && displayIndex <= payload.totalCount else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                payload.totalCount
            )
            return
        }

        guard onJumpToMessage(displayIndex) else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                payload.totalCount
            )
            return
        }

        jumpError = nil
        dismiss()
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
