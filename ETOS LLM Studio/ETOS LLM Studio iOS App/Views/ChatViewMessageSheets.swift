// ============================================================================
// ChatViewMessageSheets.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载聊天页的消息操作、会话信息与消息详情弹窗组件。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct MessageActionSheet: View {
    let payload: MessageActionSheetPayload
    let hasDisplayVersions: Bool
    let displayVersionCount: Int
    let displayCurrentVersionIndex: Int
    let canRetry: Bool
    let canRewrite: Bool
    let allMessages: [ChatMessage]
    let providers: [Provider]
    @ObservedObject var ttsManager: TTSManager
    let onEdit: (ChatMessage) -> Void
    let onRewrite: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void
    let onShowFullError: (String) -> Void
    let onBranch: (ChatMessage) -> Void
    let onExport: (ChatTranscriptExportFormat, Bool, Bool, ChatMessage?) -> Void
    let onSpeak: (ChatMessage) -> Void
    let onSwitchVersion: (Int, ChatMessage) -> Void
    let onDeleteVersion: (ChatMessage, Int) -> Void
    let onDelete: (ChatMessage) -> Void
    let onDownloadImages: ([String]) -> Void
    let onAskAI: (String, ChatMessage) -> Void
    let onSelectMultiple: (ChatMessage) -> Void
    let onJumpToMessage: (Int) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var includeReasoning = true
    @State private var includeSystemPrompt = true
    @State private var jumpInput: String = ""
    @State private var jumpError: String?

    private var message: ChatMessage {
        payload.message
    }

    private var hasAttachments: Bool {
        message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
    }

    private var messageIndex: Int? {
        allMessages.firstIndex(where: { $0.id == message.id })
    }

    private var displayIndex: Int? {
        messageIndex.map { $0 + 1 }
    }

    private var totalMessageCount: Int {
        allMessages.count
    }

    private var resolvedCostEstimate: MessageCostEstimate? {
        let estimate = MessageCostResolver.resolvedCost(
            for: message,
            providers: providers
        )
        guard let estimate, estimate.totalCost > 0 else { return nil }
        return estimate
    }

    private var isSpeakingThisMessage: Bool {
        ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                        Button {
                            onDownloadImages(imageFileNames)
                        } label: {
                            Label(NSLocalizedString("下载", comment: "Download generated image"), systemImage: "square.and.arrow.down")
                        }
                    }

                    if !hasAttachments {
                        Button {
                            onEdit(message)
                        } label: {
                            Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
                        }
                    }

                    if canRewrite {
                        Button {
                            onRewrite(message)
                        } label: {
                            Label(NSLocalizedString("重写", comment: "Rewrite message action"), systemImage: "wand.and.stars")
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

                    NavigationLink {
                        MessageTextSelectionView(message: message) { selectedText in
                            onAskAI(selectedText, message)
                        }
                    } label: {
                        Label(
                            NSLocalizedString("选定文字", comment: "Open message text selection"),
                            systemImage: "character.cursor.ibeam"
                        )
                    }

                    Button {
                        onSelectMultiple(message)
                    } label: {
                        Label(NSLocalizedString("多选", comment: "Enter message selection mode"), systemImage: "checkmark.circle")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(message)
                    } label: {
                        Label(hasDisplayVersions ? NSLocalizedString("删除所有版本", comment: "") : NSLocalizedString("删除消息", comment: ""), systemImage: "trash.fill")
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

                messageSupplementarySections
                exportSection
                messageInfoSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
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

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Toggle(NSLocalizedString("包含思考", comment: ""), isOn: $includeReasoning)
            Toggle(NSLocalizedString("包含系统提示词", comment: ""), isOn: $includeSystemPrompt)

            ForEach(MessageActionExportScope.allCases) { scope in
                Menu {
                    ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                        Button {
                            onExport(
                                format,
                                includeReasoning,
                                includeSystemPrompt,
                                scope == .upToMessage ? message : nil
                            )
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
        } header: {
            Text(NSLocalizedString("导出", comment: ""))
        } footer: {
            Text(NSLocalizedString("PNG 仅导出聊天界面可见内容，不会包含系统提示词。", comment: "Chat image export system prompt privacy note"))
        }
    }

    @ViewBuilder
    private var messageInfoSection: some View {
        Section(NSLocalizedString("消息信息", comment: "")) {
            LabeledContent(NSLocalizedString("角色", comment: "")) {
                Text(roleDescription(message.role))
            }

            if let displayIndex {
                LabeledContent(NSLocalizedString("列表位置", comment: "")) {
                    Text(
                        String(
                            format: NSLocalizedString("第 %d / %d 条", comment: ""),
                            displayIndex,
                            totalMessageCount
                        )
                    )
                }
            }

            if let modelReference = message.modelReference {
                LabeledContent(NSLocalizedString("提供商", comment: "")) {
                    Text(modelReference.providerName)
                        .textSelection(.enabled)
                }
                LabeledContent(NSLocalizedString("模型名称", comment: "")) {
                    Text(modelReference.modelDisplayName)
                        .textSelection(.enabled)
                }
                LabeledContent(NSLocalizedString("模型ID", comment: "")) {
                    Text(modelReference.modelName)
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("唯一标识", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                Text(message.id.uuidString)
                    .etFont(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var messageSupplementarySections: some View {
        if totalMessageCount > 0 {
            Section(NSLocalizedString("快速定位", comment: "Quick message jump section title")) {
                TextField(
                    String(
                        format: NSLocalizedString("输入消息序号（1-%d）", comment: "Message index input placeholder"),
                        totalMessageCount
                    ),
                    text: $jumpInput
                )
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    submitJump()
                }

                Button {
                    submitJump()
                } label: {
                    Label(NSLocalizedString("跳转到该条消息", comment: "Jump to message button title"), systemImage: "location")
                }

                if let jumpError, !jumpError.isEmpty {
                    Text(jumpError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }

        if let usage = message.tokenUsage, usage.hasData {
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
                if let cacheWrite = usage.cacheWriteTokens, cacheWrite > 0 {
                    LabeledContent(NSLocalizedString("缓存写入 Tokens", comment: "Cache write tokens label")) {
                        Text("\(cacheWrite)")
                    }
                }
                if let cacheRead = usage.cacheReadTokens, cacheRead > 0 {
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
                if let costEstimate = resolvedCostEstimate {
                    MessageCostDetailRows(estimate: costEstimate)
                }
            }
        } else if let metrics = message.responseMetrics, metrics.isTokenPerSecondEstimated {
            Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                Text(NSLocalizedString("当前响应未返回官方 token 用量（仅有估算速度）。", comment: "No official token usage returned hint"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                if let costEstimate = resolvedCostEstimate {
                    MessageCostDetailRows(estimate: costEstimate)
                }
            }
        } else if let costEstimate = resolvedCostEstimate {
            Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                MessageCostDetailRows(estimate: costEstimate)
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

        if let metrics = message.responseMetrics,
           let samples = metrics.speedSamples,
           !samples.isEmpty {
            Section(NSLocalizedString("流式速度曲线", comment: "Streaming speed chart title")) {
                MessageInfoStreamingSpeedChart(metrics: metrics)
            }
        }
    }

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

        guard displayIndex >= 1 && displayIndex <= totalMessageCount else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                totalMessageCount
            )
            return
        }

        guard onJumpToMessage(displayIndex) else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                totalMessageCount
            )
            return
        }

        jumpError = nil
        dismiss()
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
        case .png:
            return "photo"
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
    let tags: [SessionTag]

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onCompress: () -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onExport: (ChatTranscriptExportFormat, Bool, Bool) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        SessionRowCard(isCurrent: isCurrent) {
            rowContent
        }
        .contextMenu {
            contextMenuContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
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
                SessionListRowContentBody(
                    title: session.name,
                    subtitle: sessionPickerSubtitle,
                    footnote: nil,
                    tags: tags,
                    isCurrent: isCurrent,
                    isRunning: isRunning
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
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
            onCompress()
        } label: {
            Label(NSLocalizedString("压缩为续聊", comment: "Context compression session action"), systemImage: "rectangle.compress.vertical")
        }
        .disabled(session.isTemporary)

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
            sessionExportReasoningMenu(includeReasoning: true)
            sessionExportReasoningMenu(includeReasoning: false)
        } label: {
            Label(NSLocalizedString("导出会话", comment: ""), systemImage: "square.and.arrow.up")
        }

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func sessionExportReasoningMenu(includeReasoning: Bool) -> some View {
        Menu(includeReasoning
            ? NSLocalizedString("包含思考", comment: "")
            : NSLocalizedString("不包含思考", comment: "")) {
            Menu(NSLocalizedString("包含系统提示词", comment: "")) {
                sessionTextExportButtons(includeReasoning: includeReasoning, includeSystemPrompt: true)
            }
            Menu(NSLocalizedString("不包含系统提示词", comment: "")) {
                sessionTextExportButtons(includeReasoning: includeReasoning, includeSystemPrompt: false)
            }
            Button {
                onExport(.png, includeReasoning, false)
            } label: {
                Label(NSLocalizedString("PNG", comment: "Export format"), systemImage: "photo")
            }
        }
    }

    @ViewBuilder
    private func sessionTextExportButtons(includeReasoning: Bool, includeSystemPrompt: Bool) -> some View {
        ForEach([ChatTranscriptExportFormat.pdf, .markdown, .text], id: \.self) { format in
            Button {
                onExport(format, includeReasoning, includeSystemPrompt)
            } label: {
                Label(format.displayName, systemImage: sessionExportIconName(for: format))
            }
        }
    }

    private func sessionExportIconName(for format: ChatTranscriptExportFormat) -> String {
        switch format {
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "number.square"
        case .text:
            return "doc.plaintext"
        case .png:
            return "photo"
        }
    }

    private var sessionPickerSubtitle: String? {
        if let searchSummary, !searchSummary.isEmpty {
            return searchSummary
        }
        return session.topicPrompt
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
