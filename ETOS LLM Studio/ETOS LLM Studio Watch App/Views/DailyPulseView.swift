// ============================================================================
// DailyPulseView.swift
// ============================================================================
// watchOS 每日脉冲视图
//
// 功能特性:
// - 展示每日脉冲卡片与核心状态
// - 支持手动生成、自动补生成、关注焦点输入
// - 支持卡片反馈、加入任务与继续聊天
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared

struct DailyPulseView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var pulseManager = DailyPulseManager.shared
    @ObservedObject private var deliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared

    @State private var expandedCardIDs: Set<UUID> = []
    @State private var reminderTimeDraft = ""
    @State private var statusMessage: String?

    var body: some View {
        List {
            if pulseManager.todayRun != nil || pulseManager.isPreparingTodayPulse {
                todayPulseSection
            }
            generationSection
            deliverySection
            focusSection
            tomorrowCurationSection
            pulseTasksSection
            feedbackHistorySection
            externalSourcesSection
            if pulseManager.todayRun == nil && !pulseManager.isPreparingTodayPulse {
                todayPulseSection
            }
        }
        .navigationTitle("每日脉冲")
        .task {
            syncReminderTimeDraft()
            await pulseManager.generateIfNeeded()
            pulseManager.markTodayRunViewed()
            await notificationCenter.refreshAuthorizationStatus()
        }
        .onChange(of: pulseManager.todayRun?.dayKey) { _, _ in
            pulseManager.markTodayRunViewed()
        }
        .onChange(of: deliveryCoordinator.reminderTimeText) { _, _ in
            syncReminderTimeDraft()
        }
        .alert("每日脉冲", isPresented: alertBinding) {
            Button("好的", role: .cancel) {
                statusMessage = nil
                pulseManager.clearError()
            }
        } message: {
            Text(pulseManager.lastErrorMessage ?? statusMessage ?? "")
        }
    }

    private var generationSection: some View {
        Section {
            Toggle("每日首次打开自动补生成", isOn: $pulseManager.autoGenerateEnabled)

            if let run = pulseManager.latestRun {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.headline)
                        .etFont(.footnote.weight(.semibold))
                    Text(summaryText(for: run))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if pulseManager.isPreparingTodayPulse {
                VStack(alignment: .leading, spacing: 6) {
                    Label("今天这一期正在准备中", systemImage: "hourglass")
                        .etFont(.footnote.weight(.semibold))
                    Text(preparationStatusText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("还没有每日脉冲记录。你可以先手动生成一份今天的主动情报卡片。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await pulseManager.generateNow()
                    if pulseManager.lastErrorMessage == nil {
                        statusMessage = "已尝试生成最新的每日脉冲。"
                    }
                }
            } label: {
                HStack {
                    Label("立即生成", systemImage: "sparkles")
                    Spacer()
                    if pulseManager.isGenerating {
                        ProgressView()
                    }
                }
            }
            .disabled(pulseManager.isGenerating)
        } header: {
            Text("生成")
        } footer: {
            Text("会优先参考最近聊天、记忆系统、请求日志、反馈历史、明日策展与当前关注焦点，并可选结合外部上下文生成约 3 张卡片。")
        }
    }

    private var deliverySection: some View {
        Section {
            Toggle("晨间提醒", isOn: $deliveryCoordinator.reminderEnabled)

            if deliveryCoordinator.reminderEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("提醒时间")
                        .etFont(.footnote.weight(.semibold))
                    TextField("08:30", text: $reminderTimeDraft.watchKeyboardNewlineBinding())
                        .onChange(of: reminderTimeDraft) { _, newValue in
                            applyReminderTimeDraftIfPossible(newValue, showErrorWhenInvalid: false)
                        }
                        .onSubmit {
                            applyReminderTimeDraftIfPossible(reminderTimeDraft, showErrorWhenInvalid: true)
                        }
                    Text("请用 24 小时制输入，例如 08:30。")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if notificationCenter.authorizationStatus == .denied {
                    Text("通知权限未开启，请在 iPhone 的 Watch 通知设置里允许 ETOS LLM Studio 发送提醒。")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("主动送达")
        } footer: {
            Text(deliveryCoordinator.reminderStatusText)
        }
    }

    private var focusSection: some View {
        Section {
            TextField("例如：继续推进某个项目、帮我整理下一步、关注最近反复提到的话题", text: $pulseManager.focusText, axis: .vertical)
                .lineLimit(2...4)

            if !pulseManager.focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(role: .destructive) {
                    pulseManager.focusText = ""
                } label: {
                    Label("清空关注焦点", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("当前关注焦点")
        } footer: {
            Text("这里的内容会参与下一次每日脉冲生成，用来告诉 AI 你最近最想优先看的方向。")
        }
    }

    private var tomorrowCurationSection: some View {
        Section {
            TextField("例如：明天优先帮我跟进 PR、安排会议、看某个项目的下一步", text: $pulseManager.tomorrowCurationText, axis: .vertical)
                .lineLimit(2...4)

            if let pending = pulseManager.pendingCuration {
                Label("将优先用于 \(pending.targetDayKey) 的每日脉冲", systemImage: "calendar.badge.clock")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !pulseManager.tomorrowCurationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(role: .destructive) {
                    pulseManager.clearTomorrowCuration()
                } label: {
                    Label("清空明日策展", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("明日想看什么")
        } footer: {
            Text("这里更像 Pulse 的“明天想看什么”。到达目标日期并生成下一期时，会优先纳入这段策展输入。")
        }
    }

    @ViewBuilder
    private var pulseTasksSection: some View {
        Section {
            if pulseManager.pendingTasks.isEmpty && pulseManager.completedTasksPreview.isEmpty {
                Text("还没有 Pulse 任务。你可以把下方卡片转成待跟进任务，后续生成时也会参考这些未完成项。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pulseManager.pendingTasks.prefix(5)) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.title)
                            .etFont(.footnote.weight(.semibold))
                        if !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(task.details)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button {
                                pulseManager.toggleTaskCompletion(id: task.id)
                            } label: {
                                Label("完成", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)

                            Button(role: .destructive) {
                                pulseManager.removeTask(id: task.id)
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !pulseManager.completedTasksPreview.isEmpty {
                    ForEach(pulseManager.completedTasksPreview) { task in
                        Label(task.title, systemImage: "checkmark.circle.fill")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        pulseManager.clearCompletedTasks()
                    } label: {
                        Label("清理已完成任务", systemImage: "checkmark.circle.trianglebadge.exclamationmark")
                    }
                }
            }
        } header: {
            Text("Pulse 任务")
        } footer: {
            Text("Pulse 任务会跨天保留，并在下一次每日脉冲生成时作为“还需要推进的事情”参与策展。")
        }
    }

    @ViewBuilder
    private var feedbackHistorySection: some View {
        Section {
            if pulseManager.feedbackHistoryPreview.isEmpty {
                Text("还没有反馈历史。你对卡片点赞、降权、隐藏或保存后，这些信号会参与后续每日脉冲生成。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pulseManager.feedbackHistoryPreview) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(historyTitle(for: event))
                            .etFont(.footnote.weight(.semibold))
                        Text(event.cardTitle)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                NavigationLink {
                    DailyPulseFeedbackHistoryView()
                } label: {
                    Label("查看完整反馈历史", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
            }
        } header: {
            Text("反馈历史")
        } footer: {
            Text("反馈历史会作为长期偏好信号保留；进入完整历史页后，你可以逐条删除或整体清空。")
        }
    }

    private var externalSourcesSection: some View {
        Section {
            Toggle("纳入 MCP 服务器能力", isOn: $pulseManager.includeMCPContext)
            Toggle("纳入快捷指令能力", isOn: $pulseManager.includeShortcutContext)
            Toggle("纳入最近外部结果", isOn: $pulseManager.includeRecentExternalResults)
            Toggle("纳入公告与趋势信号", isOn: $pulseManager.includeTrendContext)

            if !pulseManager.externalSignalPreview.isEmpty {
                ForEach(pulseManager.externalSignalPreview) { signal in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(externalSignalTitle(for: signal))
                            .etFont(.caption2.weight(.semibold))
                        Text(signal.preview)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Button(role: .destructive) {
                    pulseManager.clearExternalSignals()
                } label: {
                    Label("清空外部信号历史", systemImage: "trash")
                }
            }
        } header: {
            Text("外部上下文")
        } footer: {
            Text(externalSourcesFooterText)
        }
    }

    private var externalSourcesFooterText: String {
        var parts: [String] = [
            "前两项会纳入可调用能力描述；“最近外部结果”会纳入快捷指令与 MCP 的最近结果；“公告与趋势信号”会纳入应用公告和已积累的趋势片段。"
        ]
        if pulseManager.externalSignalPreview.isEmpty {
            parts.append("还没有积累到可复用的外部信号历史。快捷指令执行、MCP 输出和公告变化会逐步沉淀到这里。")
        }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var todayPulseSection: some View {
        if let run = pulseManager.todayRun {
            let visibleCards = run.visibleCards
            Section {
                if visibleCards.isEmpty {
                    Text("这次生成的卡片都被你隐藏了。你可以重新生成一份新的每日脉冲。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleCards) { card in
                        cardView(card, runID: run.id)
                    }
                }
            } header: {
                Text("今天的卡片")
            } footer: {
                Text(summaryText(for: run))
            }
        } else if pulseManager.isPreparingTodayPulse {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("正在为你准备今天的每日脉冲", systemImage: "sparkles")
                        .etFont(.footnote.weight(.semibold))
                    Text(preparationStatusText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
            } header: {
                Text("今天的卡片")
            }
        } else {
            Section {
                Text("今天还没有生成新的每日脉冲。你可以立即生成，或者先写一点“明日想看什么”再回来。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("今天的卡片")
            }
        }
    }

    private func cardView(_ card: DailyPulseCard, runID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(card.title)
                    .etFont(.headline)
                Spacer(minLength: 8)
                feedbackBadge(for: card)
            }

            Text(card.summary)
                .etFont(.footnote)
            Text(card.whyRecommended)
                .etFont(.caption2)
                .foregroundStyle(.secondary)

            Button {
                toggleExpansion(for: card.id)
            } label: {
                Label(
                    expandedCardIDs.contains(card.id) ? "收起更多" : "展开更多",
                    systemImage: expandedCardIDs.contains(card.id) ? "chevron.up.circle" : "ellipsis.circle"
                )
            }
            .buttonStyle(.bordered)

            if expandedCardIDs.contains(card.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Markdown(card.detailsMarkdown)
                        .etFont(.footnote)
                        .etDailyPulseMarkdownFontStyle(sampleText: card.detailsMarkdown)

                    Button {
                        let hadSavedSession = card.savedSessionID != nil
                        viewModel.continueDailyPulseCard(card, from: runID)
                        statusMessage = hadSavedSession
                            ? "已打开这张卡片对应的会话，并填好继续追问。返回上一层即可继续。"
                            : "已为这张卡片创建正式会话，并填好继续追问。返回上一层即可继续。"
                    } label: {
                        Label("继续聊", systemImage: "arrow.up.right.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        let existing = pulseManager.linkedTask(cardID: card.id, runID: runID)
                        if pulseManager.addTaskFromCard(cardID: card.id, runID: runID) != nil {
                            statusMessage = existing == nil ? "已加入 Pulse 任务。" : "这张卡片已经在任务列表里。"
                        }
                    } label: {
                        Label(
                            pulseManager.linkedTask(cardID: card.id, runID: runID) == nil ? "加入任务" : "已在任务中",
                            systemImage: pulseManager.linkedTask(cardID: card.id, runID: runID) == nil ? "checklist" : "checkmark.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)

                    HStack {
                        Button {
                            pulseManager.applyFeedback(.liked, cardID: card.id, runID: runID)
                        } label: {
                            Label("喜欢", systemImage: card.feedback == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        .tint(.pink)

                        Button {
                            pulseManager.applyFeedback(.disliked, cardID: card.id, runID: runID)
                        } label: {
                            Label("降权", systemImage: card.feedback == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        }
                        .tint(.orange)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        pulseManager.applyFeedback(.hidden, cardID: card.id, runID: runID)
                    } label: {
                        Label("隐藏这张卡片", systemImage: "eye.slash")
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func toggleExpansion(for cardID: UUID) {
        if expandedCardIDs.contains(cardID) {
            expandedCardIDs.remove(cardID)
        } else {
            expandedCardIDs.insert(cardID)
        }
    }

    private func summaryText(for run: DailyPulseRun) -> String {
        let dateText = run.generatedAt.formatted(date: .abbreviated, time: .shortened)
        return "生成于 \(dateText) · 可见卡片 \(run.visibleCards.count)/\(run.cards.count) · 仅保留当天"
    }

    private var preparationStatusText: String {
        if let startedAt = pulseManager.lastPreparationStartedAt {
            let timeText = startedAt.formatted(date: .omitted, time: .shortened)
            return "系统已在 \(timeText) 开始准备今天这一期。你可以稍等片刻，或留在这里等待卡片刷新。"
        }
        return "系统正在根据你的聊天、记忆、反馈与外部上下文准备今天这一期。"
    }

    private func historyTitle(for event: DailyPulseFeedbackEvent) -> String {
        switch event.action {
        case .liked:
            return "已喜欢 · \(event.dayKey)"
        case .disliked:
            return "已降权 · \(event.dayKey)"
        case .hidden:
            return "已隐藏 · \(event.dayKey)"
        case .saved:
            return "已保存为会话 · \(event.dayKey)"
        }
    }

    private func externalSignalTitle(for signal: DailyPulseExternalSignal) -> String {
        let prefix: String
        switch signal.source {
        case .shortcutResult:
            prefix = signal.isFailure ? "快捷指令失败" : "快捷指令结果"
        case .mcpOutput:
            prefix = "MCP 输出"
        case .mcpError:
            prefix = "MCP 错误"
        case .announcement:
            prefix = "公告/趋势"
        }
        return "\(prefix) · \(signal.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder
    private func feedbackBadge(for card: DailyPulseCard) -> some View {
        switch card.feedback {
        case .liked:
            Label("已喜欢", systemImage: "heart.fill")
                .etFont(.caption2)
                .foregroundStyle(.pink)
        case .disliked:
            Label("已降权", systemImage: "hand.thumbsdown.fill")
                .etFont(.caption2)
                .foregroundStyle(.orange)
        case .hidden:
            Label("已隐藏", systemImage: "eye.slash.fill")
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        case .none:
            if card.savedSessionID != nil {
                Label("已保存", systemImage: "bookmark.fill")
                    .etFont(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: {
                let error = pulseManager.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let info = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !error.isEmpty || !info.isEmpty
            },
            set: { isPresented in
                guard !isPresented else { return }
                statusMessage = nil
                pulseManager.clearError()
            }
        )
    }

    private func syncReminderTimeDraft() {
        reminderTimeDraft = deliveryCoordinator.reminderTimeText
    }

    private func applyReminderTimeDraftIfPossible(_ input: String, showErrorWhenInvalid: Bool) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            syncReminderTimeDraft()
            return
        }
        guard let components = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: trimmed) else {
            if showErrorWhenInvalid {
                statusMessage = "提醒时间请输入 24 小时制，例如 08:30。"
                syncReminderTimeDraft()
            }
            return
        }

        deliveryCoordinator.reminderHour = components.hour
        deliveryCoordinator.reminderMinute = components.minute

        let normalized = deliveryCoordinator.reminderTimeText
        if reminderTimeDraft != normalized {
            reminderTimeDraft = normalized
        }
    }
}

private extension View {
    @ViewBuilder
    func etDailyPulseMarkdownFontStyle(sampleText: String) -> some View {
        let bodyFontName = FontLibrary.resolvePostScriptName(for: .body, sampleText: sampleText)
        let emphasisFontName = FontLibrary.resolvePostScriptName(for: .emphasis, sampleText: sampleText)
        let strongFontName = FontLibrary.resolvePostScriptName(for: .strong, sampleText: sampleText)
        let codeFontName = FontLibrary.resolvePostScriptName(for: .code, sampleText: sampleText)

        self
            .markdownTextStyle {
                if let bodyFontName, !bodyFontName.isEmpty {
                    FontFamily(.custom(bodyFontName))
                }
            }
            .markdownTextStyle(\.emphasis) {
                if let emphasisFontName, !emphasisFontName.isEmpty {
                    FontFamily(.custom(emphasisFontName))
                }
                FontStyle(.italic)
            }
            .markdownTextStyle(\.strong) {
                if let strongFontName, !strongFontName.isEmpty {
                    FontFamily(.custom(strongFontName))
                }
            }
            .markdownTextStyle(\.code) {
                if let codeFontName, !codeFontName.isEmpty {
                    FontFamily(.custom(codeFontName))
                } else {
                    FontFamily(.system(.monospaced))
                }
            }
    }
}
