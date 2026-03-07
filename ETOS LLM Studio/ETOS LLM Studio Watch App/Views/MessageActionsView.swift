// ============================================================================
// MessageActionsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息操作菜单视图
//
// 功能特性:
// - 提供编辑、重试、删除单条消息的快捷操作
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct MessageActionsView: View {
    
    // MARK: - 属性与操作
    
    let message: ChatMessage
    let canRetry: Bool
    let onEdit: () -> Void
    let onRetry: (ChatMessage) -> Void
    let onDelete: () -> Void
    let onDeleteCurrentVersion: () -> Void
    let onSwitchVersion: (Int) -> Void
    let onBranch: (Bool) -> Void
    let onShowFullError: ((String) -> Void)?
    let supportsMathRenderToggle: Bool
    let isMathRenderingEnabled: Bool
    let onToggleMathRendering: () -> Void
    
    let messageIndex: Int?
    let totalMessages: Int

    init(
        message: ChatMessage,
        canRetry: Bool,
        onEdit: @escaping () -> Void,
        onRetry: @escaping (ChatMessage) -> Void,
        onDelete: @escaping () -> Void,
        onDeleteCurrentVersion: @escaping () -> Void,
        onSwitchVersion: @escaping (Int) -> Void,
        onBranch: @escaping (Bool) -> Void,
        onShowFullError: ((String) -> Void)?,
        supportsMathRenderToggle: Bool = false,
        isMathRenderingEnabled: Bool = false,
        onToggleMathRendering: @escaping () -> Void = {},
        messageIndex: Int?,
        totalMessages: Int
    ) {
        self.message = message
        self.canRetry = canRetry
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.onDeleteCurrentVersion = onDeleteCurrentVersion
        self.onSwitchVersion = onSwitchVersion
        self.onBranch = onBranch
        self.onShowFullError = onShowFullError
        self.supportsMathRenderToggle = supportsMathRenderToggle
        self.isMathRenderingEnabled = isMathRenderingEnabled
        self.onToggleMathRendering = onToggleMathRendering
        self.messageIndex = messageIndex
        self.totalMessages = totalMessages
    }
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss
    @State private var showDeleteConfirm = false
    @State private var showDeleteVersionConfirm = false
    @State private var showBranchOptions = false

    // MARK: - 视图主体
    
    var body: some View {
        // 有音频或图片附件的消息不显示编辑按钮
        let hasAttachments = message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
        
        Form {
            Section {
                if !hasAttachments {
                    Button {
                        onEdit()
                        dismiss()
                    } label: {
                        Label("编辑消息", systemImage: "pencil")
                    }
                }

                if canRetry {
                    Button {
                        onRetry(message)
                        dismiss()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
                
                // 如果错误消息有完整内容（被截断），显示查看完整响应按钮
                if message.role == .error, let fullContent = message.fullErrorContent, let onShowFullError {
                    Button {
                        onShowFullError(fullContent)
                        dismiss()
                    } label: {
                        Label("查看完整响应", systemImage: "doc.text.magnifyingglass")
                    }
                }
                
                Button {
                    showBranchOptions = true
                } label: {
                    Label("从此处创建分支", systemImage: "arrow.triangle.branch")
                }

                if supportsMathRenderToggle {
                    Button {
                        onToggleMathRendering()
                        dismiss()
                    } label: {
                        Label(
                            isMathRenderingEnabled ? "取消渲染公式" : "渲染公式",
                            systemImage: isMathRenderingEnabled ? "xmark.circle" : "function"
                        )
                    }
                }
            }
            
            // 版本管理菜单
            if message.hasMultipleVersions {
                Section("版本管理") {
                    Picker("选择版本", selection: Binding(
                        get: { message.getCurrentVersionIndex() },
                        set: { newIndex in
                            onSwitchVersion(newIndex)
                            dismiss()
                        }
                    )) {
                        ForEach(0..<message.getAllVersions().count, id: \.self) { index in
                            Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                                .tag(index)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    
                    if message.getAllVersions().count > 1 {
                        Button(role: .destructive) {
                            showDeleteVersionConfirm = true
                        } label: {
                            Label("删除当前版本", systemImage: "trash")
                        }
                    }
                }
            }
            
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(message.hasMultipleVersions ? "删除所有版本" : "删除消息", systemImage: "trash.fill")
                }
            }
            
            Section(header: Text("详细信息")) {
                if let index = messageIndex {
                    VStack(alignment: .leading) {
                        Text("会话位置")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: NSLocalizedString("第 %d / %d 条", comment: ""), index + 1, totalMessages))
                            .font(.caption2)
                    }
                }
                
                if message.hasMultipleVersions {
                    VStack(alignment: .leading) {
                        Text("版本信息")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(
                            String(
                                format: NSLocalizedString("当前显示第 %d / %d 版", comment: ""),
                                message.getCurrentVersionIndex() + 1,
                                message.getAllVersions().count
                            )
                        )
                            .font(.caption2)
                    }
                }
                
                VStack(alignment: .leading) {
                    Text("消息 ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(message.id.uuidString)
                        .font(.caption2)
                }
            }
            
            if let usage = message.tokenUsage, usage.hasData {
                Section("Token 用量") {
                    if let prompt = usage.promptTokens {
                        LabeledContent("发送 Tokens", value: "\(prompt)")
                    }
                    if let completion = usage.completionTokens {
                        LabeledContent("接收 Tokens", value: "\(completion)")
                    }
                    if let total = usage.totalTokens, (usage.promptTokens != total || usage.completionTokens != total) {
                        LabeledContent("总计", value: "\(total)")
                    } else if let totalOnly = usage.totalTokens, usage.promptTokens == nil && usage.completionTokens == nil {
                        LabeledContent("总计", value: "\(totalOnly)")
                    }
                }
            }

            if let metrics = message.responseMetrics {
                Section(NSLocalizedString("响应测速", comment: "Response speed metrics section title")) {
                    if let firstToken = metrics.timeToFirstToken {
                        LabeledContent(NSLocalizedString("首字时间", comment: "Time to first token"), value: formatDuration(firstToken))
                    }
                    if let totalDuration = metrics.totalResponseDuration {
                        LabeledContent(NSLocalizedString("总回复时间", comment: "Total response time"), value: formatDuration(totalDuration))
                    }
                    if let completionTokens = metrics.completionTokensForSpeed {
                        LabeledContent(NSLocalizedString("测速 Tokens", comment: "Tokens used for speed calculation"), value: "\(completionTokens)")
                    }
                    if let speed = metrics.tokenPerSecond {
                        LabeledContent(NSLocalizedString("响应速度", comment: "Response speed"), value: formatSpeed(speed, estimated: metrics.isTokenPerSecondEstimated))
                    }
                }
            }

            if let metrics = message.responseMetrics,
               let samples = metrics.speedSamples,
               !samples.isEmpty {
                Section(NSLocalizedString("流式速度曲线", comment: "Streaming speed chart title")) {
                    MessageActionsStreamingSpeedChart(metrics: metrics)
                }
            }
        }
        .navigationTitle("操作")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认删除消息", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(message.hasMultipleVersions ? "删除后将无法恢复这条消息的所有版本。" : "删除后无法恢复这条消息。")
        }
        .alert("确认删除当前版本", isPresented: $showDeleteVersionConfirm) {
            Button("删除", role: .destructive) {
                onDeleteCurrentVersion()
                dismiss()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后将无法恢复此版本的内容。")
        }
        .confirmationDialog("创建分支选项", isPresented: $showBranchOptions, titleVisibility: .visible) {
            Button("仅复制消息历史") {
                onBranch(false)
                dismiss()
            }
            Button("复制消息历史和提示词") {
                onBranch(true)
                dismiss()
            }
            Button("取消", role: .cancel) { }
        } message: {
            if let index = messageIndex {
                Text(String(format: NSLocalizedString("将从第 %d 条消息处创建新的分支会话。", comment: ""), index + 1))
            }
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
}

private struct MessageActionsStreamingSpeedChart: View {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(String(format: "%.2f %@", currentSpeed, NSLocalizedString("token/s", comment: "Tokens per second unit")))
                    .font(.caption2.monospacedDigit())
                Spacer(minLength: 0)
                Text(NSLocalizedString("每秒采样", comment: "Per-second speed sampling"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let points = normalizedPoints(in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                            )
                    }

                    if let last = points.last {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .position(last)
                    }
                }
            }
            .frame(height: 70)

            if let fluctuation {
                Text("\(NSLocalizedString("波动", comment: "Speed fluctuation label")) \(String(format: "%.2f %@", fluctuation, NSLocalizedString("token/s", comment: "Tokens per second unit")))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
