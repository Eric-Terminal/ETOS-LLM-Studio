// ============================================================================
// ChatViewMessageSheets.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载聊天页的消息操作、会话信息与消息详情弹窗组件。
// ============================================================================

import SwiftUI
import Foundation
import Shared
import UIKit

/// 会话信息弹窗的数据载体，用于隔离 UI 与业务模型
struct SessionPickerInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

struct MessageActionSheet: View {
    let payload: MessageActionSheetPayload
    let hasDisplayVersions: Bool
    let displayVersionCount: Int
    let displayCurrentVersionIndex: Int
    let canRetry: Bool
    let allMessages: [ChatMessage]
    @ObservedObject var ttsManager: TTSManager
    let onEdit: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void
    let onShowFullError: (String) -> Void
    let onBranch: (ChatMessage) -> Void
    let onExport: (ChatTranscriptExportFormat, Bool, ChatMessage?) -> Void
    let onSpeak: (ChatMessage) -> Void
    let onSwitchVersion: (Int, ChatMessage) -> Void
    let onDeleteVersion: (ChatMessage, Int) -> Void
    let onDelete: (ChatMessage) -> Void
    let onDownloadImages: ([String]) -> Void
    let onCopy: (ChatMessage) -> Void
    let onInfo: (ChatMessage, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeReasoning = true

    private var message: ChatMessage {
        payload.message
    }

    private var hasAttachments: Bool {
        message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
    }

    private var messageIndex: Int? {
        allMessages.firstIndex(where: { $0.id == message.id })
    }

    private var isSpeakingThisMessage: Bool {
        ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !hasAttachments {
                        Button {
                            onEdit(message)
                        } label: {
                            Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
                        }
                    }

                    if canRetry {
                        Button {
                            onRetry(message)
                        } label: {
                            Label(NSLocalizedString("重试", comment: ""), systemImage: "arrow.clockwise")
                        }
                    }

                    if message.role == .error, let fullContent = message.fullErrorContent {
                        Button {
                            onShowFullError(fullContent)
                        } label: {
                            Label(NSLocalizedString("查看完整响应", comment: ""), systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    Button {
                        onBranch(message)
                    } label: {
                        Label(NSLocalizedString("从此处创建分支", comment: ""), systemImage: "arrow.triangle.branch")
                    }

                    if message.role == .assistant || message.role == .tool || message.role == .system {
                        Button {
                            onSpeak(message)
                        } label: {
                            Label(
                                isSpeakingThisMessage ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""),
                                systemImage: isSpeakingThisMessage ? "stop.circle" : "speaker.wave.2"
                            )
                        }
                    }
                }

                Section(NSLocalizedString("导出", comment: "")) {
                    Toggle(NSLocalizedString("包含思考", comment: ""), isOn: $includeReasoning)

                    ForEach(MessageActionExportScope.allCases) { scope in
                        Menu {
                            ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                                Button {
                                    onExport(format, includeReasoning, scope == .upToMessage ? message : nil)
                                } label: {
                                    Label(format.displayName, systemImage: iconName(for: format))
                                }
                            }
                        } label: {
                            Label(
                                exportScopeTitle(scope),
                                systemImage: scope == .upToMessage ? "arrow.up.doc" : "square.and.arrow.up"
                            )
                        }
                    }
                }

                if hasDisplayVersions {
                    Section(NSLocalizedString("版本管理", comment: "")) {
                        ForEach(0..<displayVersionCount, id: \.self) { index in
                            Button {
                                onSwitchVersion(index, message)
                            } label: {
                                MessageVersionRow(
                                    index: index,
                                    isCurrent: index == displayCurrentVersionIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if displayVersionCount > 1 {
                                    Button(role: .destructive) {
                                        onDeleteVersion(message, index)
                                    } label: {
                                        Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                        Button {
                            onDownloadImages(imageFileNames)
                        } label: {
                            Label(NSLocalizedString("下载", comment: "Download generated image"), systemImage: "square.and.arrow.down")
                        }
                    }

                    Button {
                        onCopy(message)
                    } label: {
                        Label(NSLocalizedString("复制内容", comment: ""), systemImage: "doc.on.doc")
                    }

                    if let messageIndex {
                        Button {
                            onInfo(message, messageIndex)
                        } label: {
                            Label(NSLocalizedString("查看消息信息", comment: ""), systemImage: "info.circle")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(message)
                    } label: {
                        Label(hasDisplayVersions ? NSLocalizedString("删除所有版本", comment: "") : NSLocalizedString("删除消息", comment: ""), systemImage: "trash.fill")
                    }
                }
            }
            .navigationTitle(NSLocalizedString("消息操作", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func exportScopeTitle(_ scope: MessageActionExportScope) -> String {
        switch scope {
        case .fullSession:
            return NSLocalizedString("导出整个会话", comment: "")
        case .upToMessage:
            return NSLocalizedString("导出到此消息（含上文）", comment: "")
        }
    }

    private func iconName(for format: ChatTranscriptExportFormat) -> String {
        switch format {
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "number.square"
        case .text:
            return "doc.plaintext"
        }
    }
}

struct MessageVersionRow: View {
    let index: Int
    let isCurrent: Bool

    var body: some View {
        Label {
            HStack(spacing: 8) {
                Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                Spacer()
                if isCurrent {
                    Text(NSLocalizedString("当前", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
    }
}

/// 会话信息弹窗，展示基础状态与唯一标识
struct SessionPickerInfoSheet: View {
    let payload: SessionPickerInfoPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("会话概览", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: "")) {
                        Text(payload.session.name)
                    }
                    LabeledContent(NSLocalizedString("状态", comment: "")) {
                        Text(payload.isCurrent ? NSLocalizedString("当前会话", comment: "") : NSLocalizedString("历史会话", comment: ""))
                            .foregroundStyle(payload.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent(NSLocalizedString("消息数量", comment: "")) {
                        Text(String(format: NSLocalizedString("%d 条", comment: ""), payload.messageCount))
                    }
                }

                if let topic = payload.session.topicPrompt, !topic.isEmpty {
                    Section(NSLocalizedString("主题提示", comment: "")) {
                        Text(topic)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let enhanced = payload.session.enhancedPrompt, !enhanced.isEmpty {
                    Section(NSLocalizedString("增强提示词", comment: "")) {
                        Text(enhanced)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("唯一标识", comment: "")) {
                    Text(payload.session.id.uuidString)
                        .etFont(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(NSLocalizedString("会话信息", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
        }
    }
}

struct SessionPickerRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let searchSummary: String?

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onExport: (ChatTranscriptExportFormat, Bool) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField(NSLocalizedString("会话名称", comment: ""), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        commit()
                    }
                    .onAppear { focused = true }

                HStack {
                    Button(NSLocalizedString("保存", comment: "")) {
                        commit()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(NSLocalizedString("取消", comment: "")) {
                        onCancelRename()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .etFont(.headline)
                        if let searchSummary, !searchSummary.isEmpty {
                            Text(searchSummary)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                        } else if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isRunning {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .etFont(.footnote.bold())
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label(NSLocalizedString("切换到此会话", comment: ""), systemImage: "checkmark.circle")
            }

            Button {
                onRename()
            } label: {
                Label(NSLocalizedString("重命名", comment: ""), systemImage: "pencil")
            }

            Button {
                onBranch(false)
            } label: {
                Label(NSLocalizedString("创建提示词分支", comment: ""), systemImage: "arrow.branch")
            }

            Button {
                onBranch(true)
            } label: {
                Label(NSLocalizedString("复制历史创建分支", comment: ""), systemImage: "arrow.triangle.branch")
            }

            Button {
                onDeleteLastMessage()
            } label: {
                Label(NSLocalizedString("删除最后一条消息", comment: ""), systemImage: "delete.backward")
            }

            Button {
                onInfo()
            } label: {
                Label(NSLocalizedString("查看会话信息", comment: ""), systemImage: "info.circle")
            }

            Menu {
                Menu(NSLocalizedString("包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, true)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, true)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, true)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
                Menu(NSLocalizedString("不包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, false)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, false)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, false)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
            } label: {
                Label(NSLocalizedString("导出会话", comment: ""), systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
            }
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

/// 用于承载消息信息弹窗的数据结构，避免直接暴露ChatMessage本身。
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

                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("快速定位", comment: "Quick message jump section title"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)

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

                        Button(NSLocalizedString("跳转到该条消息", comment: "Jump to message button title")) {
                            submitJump()
                        }
                        .buttonStyle(.borderedProminent)

                        if let jumpError, !jumpError.isEmpty {
                            Text(jumpError)
                                .etFont(.footnote)
                                .foregroundStyle(.red)
                        }
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
