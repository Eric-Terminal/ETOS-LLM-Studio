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
    let onSpeak: (ChatMessage) -> Void
    let onStopSpeaking: () -> Void
    let onDelete: () -> Void
    let onDeleteCurrentVersion: () -> Void
    let onSwitchVersion: (Int) -> Void
    let onBranch: (Bool) -> Void
    let onShowFullError: ((String) -> Void)?
    let supportsMathRenderToggle: Bool
    let isMathRenderingEnabled: Bool
    let onToggleMathRendering: () -> Void
    let onJumpToMessageIndex: (Int) -> Bool
    let session: ChatSession?
    let allMessages: [ChatMessage]
    
    let messageIndex: Int?
    let totalMessages: Int

    init(
        message: ChatMessage,
        canRetry: Bool,
        onEdit: @escaping () -> Void,
        onRetry: @escaping (ChatMessage) -> Void,
        onSpeak: @escaping (ChatMessage) -> Void,
        onStopSpeaking: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDeleteCurrentVersion: @escaping () -> Void,
        onSwitchVersion: @escaping (Int) -> Void,
        onBranch: @escaping (Bool) -> Void,
        onShowFullError: ((String) -> Void)?,
        supportsMathRenderToggle: Bool = false,
        isMathRenderingEnabled: Bool = false,
        onToggleMathRendering: @escaping () -> Void = {},
        onJumpToMessageIndex: @escaping (Int) -> Bool,
        session: ChatSession?,
        allMessages: [ChatMessage],
        messageIndex: Int?,
        totalMessages: Int
    ) {
        self.message = message
        self.canRetry = canRetry
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onSpeak = onSpeak
        self.onStopSpeaking = onStopSpeaking
        self.onDelete = onDelete
        self.onDeleteCurrentVersion = onDeleteCurrentVersion
        self.onSwitchVersion = onSwitchVersion
        self.onBranch = onBranch
        self.onShowFullError = onShowFullError
        self.supportsMathRenderToggle = supportsMathRenderToggle
        self.isMathRenderingEnabled = isMathRenderingEnabled
        self.onToggleMathRendering = onToggleMathRendering
        self.onJumpToMessageIndex = onJumpToMessageIndex
        self.session = session
        self.allMessages = allMessages
        self.messageIndex = messageIndex
        self.totalMessages = totalMessages
    }
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss
    @State private var showDeleteConfirm = false
    @State private var showDeleteVersionConfirm = false
    @State private var showBranchOptions = false
    @State private var pendingRetryMessage: ChatMessage?
    @State private var jumpInput: String = ""
    @State private var jumpError: String?
    @ObservedObject private var ttsManager = TTSManager.shared

    private var responseAttemptVersionInfo: ChatResponseAttemptVersionInfo? {
        ChatResponseAttemptSupport.versionInfo(for: message, in: allMessages)
    }

    private var hasDisplayVersions: Bool {
        responseAttemptVersionInfo != nil || message.hasMultipleVersions
    }

    private var displayVersionCount: Int {
        responseAttemptVersionInfo?.totalCount ?? message.getAllVersions().count
    }

    private var displayCurrentVersionIndex: Int {
        responseAttemptVersionInfo?.currentIndex ?? message.getCurrentVersionIndex()
    }

    private var visibleAllMessages: [ChatMessage] {
        ChatResponseAttemptSupport.visibleMessages(from: allMessages)
    }

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
                        Label(NSLocalizedString("编辑消息", comment: ""), systemImage: "pencil")
                    }
                }

                if canRetry {
                    Button {
                        pendingRetryMessage = message
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("重试", comment: ""), systemImage: "arrow.clockwise")
                    }
                }
                
                // 如果错误消息有完整内容（被截断），显示查看完整响应按钮
                if message.role == .error, let fullContent = message.fullErrorContent, let onShowFullError {
                    Button {
                        onShowFullError(fullContent)
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("查看完整响应", comment: ""), systemImage: "doc.text.magnifyingglass")
                    }
                }
                
                Button {
                    showBranchOptions = true
                } label: {
                    Label(NSLocalizedString("从此处创建分支", comment: ""), systemImage: "arrow.triangle.branch")
                }

                if message.role == .assistant || message.role == .tool || message.role == .system {
                    Button {
                        if ttsManager.currentSpeakingMessageID == message.id, ttsManager.isSpeaking {
                            onStopSpeaking()
                        } else {
                            onSpeak(message)
                        }
                        dismiss()
                    } label: {
                        Label(
                            ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""),
                            systemImage: ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking ? "stop.circle" : "speaker.wave.2"
                        )
                    }
                }

                if supportsMathRenderToggle {
                    Button {
                        onToggleMathRendering()
                        dismiss()
                    } label: {
                        Label(
                            isMathRenderingEnabled ? NSLocalizedString("取消渲染公式", comment: "") : NSLocalizedString("渲染公式", comment: ""),
                            systemImage: isMathRenderingEnabled ? "xmark.circle" : "function"
                        )
                    }
                }
            }

            Section(NSLocalizedString("导出", comment: "")) {
                NavigationLink {
                    ChatExportFormatsView(
                        session: session,
                        messages: visibleAllMessages,
                        upToMessageID: nil
                    )
                } label: {
                    Label(NSLocalizedString("导出整个会话", comment: ""), systemImage: "square.and.arrow.up")
                }

                NavigationLink {
                    ChatExportFormatsView(
                        session: session,
                        messages: visibleAllMessages,
                        upToMessageID: message.id
                    )
                } label: {
                    Label(NSLocalizedString("导出到此消息（含上文）", comment: ""), systemImage: "arrow.up.doc")
                }
            }
            
            // 版本管理菜单
            if hasDisplayVersions {
                Section(NSLocalizedString("版本管理", comment: "")) {
                    Picker(NSLocalizedString("选择版本", comment: ""), selection: Binding(
                        get: { displayCurrentVersionIndex },
                        set: { newIndex in
                            onSwitchVersion(newIndex)
                            dismiss()
                        }
                    )) {
                        ForEach(0..<displayVersionCount, id: \.self) { index in
                            Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                                .tag(index)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    
                    if displayVersionCount > 1 {
                        Button(role: .destructive) {
                            showDeleteVersionConfirm = true
                        } label: {
                            Label(NSLocalizedString("删除当前版本", comment: ""), systemImage: "trash")
                        }
                    }
                }
            }
            
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(hasDisplayVersions ? NSLocalizedString("删除所有版本", comment: "") : NSLocalizedString("删除消息", comment: ""), systemImage: "trash.fill")
                }
            }
            
            Section(header: Text(NSLocalizedString("详细信息", comment: ""))) {
                if let index = messageIndex {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("会话位置", comment: ""))
                            .etFont(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: NSLocalizedString("第 %d / %d 条", comment: ""), index + 1, totalMessages))
                            .etFont(.caption2)
                    }
                }
                
                if hasDisplayVersions {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("版本信息", comment: ""))
                            .etFont(.caption)
                            .foregroundColor(.secondary)
                        Text(
                            String(
                                format: NSLocalizedString("当前显示第 %d / %d 版", comment: ""),
                                displayCurrentVersionIndex + 1,
                                displayVersionCount
                            )
                        )
                            .etFont(.caption2)
                    }
                }
                
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("消息 ID", comment: ""))
                        .etFont(.caption)
                        .foregroundColor(.secondary)
                    Text(message.id.uuidString)
                        .etFont(.caption2)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("快速定位", comment: "Quick message jump section title"))
                        .etFont(.caption)
                        .foregroundColor(.secondary)

                    TextField(
                        String(
                            format: NSLocalizedString("输入消息序号（1-%d）", comment: "Message index input placeholder"),
                            totalMessages
                        ),
                        text: $jumpInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        submitJump()
                    } label: {
                        Label(NSLocalizedString("跳转到该条消息", comment: "Jump to message button title"), systemImage: "location")
                    }

                    if let jumpError, !jumpError.isEmpty {
                        Text(jumpError)
                            .etFont(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            
            if let usage = message.tokenUsage, usage.hasData {
                Section(NSLocalizedString("Token 用量", comment: "")) {
                    if let prompt = usage.promptTokens {
                        LabeledContent(NSLocalizedString("发送 Tokens", comment: ""), value: "\(prompt)")
                    }
                    if let completion = usage.completionTokens {
                        LabeledContent(NSLocalizedString("接收 Tokens", comment: ""), value: "\(completion)")
                    }
                    if let thinking = usage.thinkingTokens {
                        LabeledContent(NSLocalizedString("思考 Tokens", comment: "Thinking tokens label"), value: "\(thinking)")
                    }
                    if let cacheWrite = usage.cacheWriteTokens {
                        LabeledContent(NSLocalizedString("缓存写入 Tokens", comment: "Cache write tokens label"), value: "\(cacheWrite)")
                    }
                    if let cacheRead = usage.cacheReadTokens {
                        LabeledContent(NSLocalizedString("缓存读取 Tokens", comment: "Cache read tokens label"), value: "\(cacheRead)")
                    }
                    if let total = usage.totalTokens, (usage.promptTokens != total || usage.completionTokens != total) {
                        LabeledContent(NSLocalizedString("总计", comment: ""), value: "\(total)")
                    } else if let totalOnly = usage.totalTokens, usage.promptTokens == nil && usage.completionTokens == nil {
                        LabeledContent(NSLocalizedString("总计", comment: ""), value: "\(totalOnly)")
                    }
                }
            }

            if let metrics = message.responseMetrics,
               metrics.timeToFirstToken != nil
                || metrics.totalResponseDuration != nil
                || metrics.reasoningDuration != nil
                || metrics.completionTokensForSpeed != nil
                || metrics.tokenPerSecond != nil {
                Section(NSLocalizedString("响应测速", comment: "Response speed metrics section title")) {
                    if let firstToken = metrics.timeToFirstToken {
                        LabeledContent(NSLocalizedString("首字时间", comment: "Time to first token"), value: formatDuration(firstToken))
                    }
                    if let totalDuration = metrics.totalResponseDuration {
                        LabeledContent(NSLocalizedString("总回复时间", comment: "Total response time"), value: formatDuration(totalDuration))
                    }
                    if let reasoningDuration = metrics.reasoningDuration {
                        LabeledContent(NSLocalizedString("思考耗时", comment: "Reasoning duration"), value: formatDuration(reasoningDuration))
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
        .navigationTitle(NSLocalizedString("操作", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .alert(NSLocalizedString("确认删除消息", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                onDelete()
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
        } message: {
            Text(hasDisplayVersions ? NSLocalizedString("删除后将无法恢复这条消息的所有版本。", comment: "") : NSLocalizedString("删除后无法恢复这条消息。", comment: ""))
        }
        .alert(NSLocalizedString("确认删除当前版本", comment: ""), isPresented: $showDeleteVersionConfirm) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                onDeleteCurrentVersion()
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("删除后将无法恢复此版本的内容。", comment: ""))
        }
        .confirmationDialog(NSLocalizedString("创建分支选项", comment: ""), isPresented: $showBranchOptions, titleVisibility: .visible) {
            Button(NSLocalizedString("仅复制消息历史", comment: "")) {
                onBranch(false)
                dismiss()
            }
            Button(NSLocalizedString("复制消息历史和提示词", comment: "")) {
                onBranch(true)
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
        } message: {
            if let index = messageIndex {
                Text(String(format: NSLocalizedString("将从第 %d 条消息处创建新的分支会话。", comment: ""), index + 1))
            }
        }
        .onDisappear {
            performPendingRetryIfNeeded()
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

        guard displayIndex >= 1 && displayIndex <= totalMessages else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                totalMessages
            )
            return
        }

        guard onJumpToMessageIndex(displayIndex) else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                totalMessages
            )
            return
        }

        jumpError = nil
        dismiss()
    }

    private func performPendingRetryIfNeeded() {
        guard let message = pendingRetryMessage else { return }
        pendingRetryMessage = nil
        Task { @MainActor in
            await Task.yield()
            onRetry(message)
        }
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
                    .etFont(.caption2.monospacedDigit())
                Spacer(minLength: 0)
                Text(NSLocalizedString("每秒采样", comment: "Per-second speed sampling"))
                    .etFont(.caption2)
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
                    .etFont(.caption2.monospacedDigit())
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
