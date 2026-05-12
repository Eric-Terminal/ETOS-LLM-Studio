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
        .navigationTitle(NSLocalizedString("每日脉冲", comment: ""))
        .task {
            await pulseManager.generateIfNeeded()
            pulseManager.markTodayRunViewed()
            await notificationCenter.refreshAuthorizationStatus()
        }
        .onChange(of: pulseManager.todayRun?.dayKey) { _, _ in
            pulseManager.markTodayRunViewed()
        }
        .alert(NSLocalizedString("每日脉冲", comment: ""), isPresented: alertBinding) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                statusMessage = nil
                pulseManager.clearError()
            }
        } message: {
            Text(pulseManager.lastErrorMessage ?? statusMessage ?? "")
        }
    }

    private var generationSection: some View {
        Section {
            Toggle(NSLocalizedString("每日首次打开自动补生成", comment: ""), isOn: $pulseManager.autoGenerateEnabled)

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
                    Label(NSLocalizedString("今天这一期正在准备中", comment: ""), systemImage: "hourglass")
                        .etFont(.footnote.weight(.semibold))
                    Text(preparationStatusText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(NSLocalizedString("还没有每日脉冲记录。你可以先手动生成一份今天的主动情报卡片。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await pulseManager.generateNow()
                    if pulseManager.lastErrorMessage == nil {
                        statusMessage = NSLocalizedString("已尝试生成最新的每日脉冲。", comment: "")
                    }
                }
            } label: {
                HStack {
                    Label(NSLocalizedString("立即生成", comment: ""), systemImage: "sparkles")
                    Spacer()
                    if pulseManager.isGenerating {
                        ProgressView()
                    }
                }
            }
            .disabled(pulseManager.isGenerating)
        } header: {
            Text(NSLocalizedString("生成", comment: ""))
        } footer: {
            Text(NSLocalizedString("会优先参考最近聊天、记忆系统、请求日志、反馈历史、明日策展与当前关注焦点，并可选结合外部上下文生成约 3 张卡片。", comment: ""))
        }
    }

    private var deliverySection: some View {
        Section {
            Toggle(NSLocalizedString("晨间提醒", comment: ""), isOn: $deliveryCoordinator.reminderEnabled)

            if deliveryCoordinator.reminderEnabled {
                DatePicker(
                    NSLocalizedString("提醒时间", comment: ""),
                    selection: reminderTimeBinding,
                    displayedComponents: .hourAndMinute
                )

                if notificationCenter.authorizationStatus == .denied {
                    Text(NSLocalizedString("通知权限未开启，请在 iPhone 的 Watch 通知设置里允许 ETOS LLM Studio 发送提醒。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NSLocalizedString("主动送达", comment: ""))
        } footer: {
            Text(deliveryCoordinator.reminderStatusText)
        }
    }

    private var focusSection: some View {
        Section {
            TextField(NSLocalizedString("例如：继续推进某个项目、帮我整理下一步、关注最近反复提到的话题", comment: ""), text: $pulseManager.focusText, axis: .vertical)
                .lineLimit(2...4)

            if !pulseManager.focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(role: .destructive) {
                    pulseManager.focusText = ""
                } label: {
                    Label(NSLocalizedString("清空关注焦点", comment: ""), systemImage: "xmark.circle")
                }
            }
        } header: {
            Text(NSLocalizedString("当前关注焦点", comment: ""))
        } footer: {
            Text(NSLocalizedString("这里的内容会参与下一次每日脉冲生成，用来告诉 AI 你最近最想优先看的方向。", comment: ""))
        }
    }

    private var tomorrowCurationSection: some View {
        Section {
            TextField(NSLocalizedString("例如：明天优先帮我跟进 PR、安排会议、看某个项目的下一步", comment: ""), text: $pulseManager.tomorrowCurationText, axis: .vertical)
                .lineLimit(2...4)

            if let pending = pulseManager.pendingCuration {
                Label(String(format: NSLocalizedString("将优先用于 %@ 的每日脉冲", comment: ""), pending.targetDayKey), systemImage: "calendar.badge.clock")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !pulseManager.tomorrowCurationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(role: .destructive) {
                    pulseManager.clearTomorrowCuration()
                } label: {
                    Label(NSLocalizedString("清空明日策展", comment: ""), systemImage: "xmark.circle")
                }
            }
        } header: {
            Text(NSLocalizedString("明日想看什么", comment: ""))
        } footer: {
            Text(NSLocalizedString("这里更像 Pulse 的“明天想看什么”。到达目标日期并生成下一期时，会优先纳入这段策展输入。", comment: ""))
        }
    }

    @ViewBuilder
    private var pulseTasksSection: some View {
        Section {
            if pulseManager.pendingTasks.isEmpty && pulseManager.completedTasksPreview.isEmpty {
                Text(NSLocalizedString("还没有 Pulse 任务。你可以把下方卡片转成待跟进任务，后续生成时也会参考这些未完成项。", comment: ""))
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
                                Label(NSLocalizedString("完成", comment: ""), systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)

                            Button(role: .destructive) {
                                pulseManager.removeTask(id: task.id)
                            } label: {
                                Label(NSLocalizedString("移除", comment: ""), systemImage: "trash")
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
                        Label(NSLocalizedString("清理已完成任务", comment: ""), systemImage: "checkmark.circle.trianglebadge.exclamationmark")
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("Pulse 任务", comment: ""))
        } footer: {
            Text(NSLocalizedString("Pulse 任务会跨天保留，并在下一次每日脉冲生成时作为“还需要推进的事情”参与策展。", comment: ""))
        }
    }

    @ViewBuilder
    private var feedbackHistorySection: some View {
        Section {
            if pulseManager.feedbackHistoryPreview.isEmpty {
                Text(NSLocalizedString("还没有反馈历史。你对卡片点赞、降权、隐藏或保存后，这些信号会参与后续每日脉冲生成。", comment: ""))
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
                    Label(NSLocalizedString("查看完整反馈历史", comment: ""), systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
            }
        } header: {
            Text(NSLocalizedString("反馈历史", comment: ""))
        } footer: {
            Text(NSLocalizedString("反馈历史会作为长期偏好信号保留；进入完整历史页后，你可以逐条删除或整体清空。", comment: ""))
        }
    }

    private var externalSourcesSection: some View {
        Section {
            Toggle(NSLocalizedString("纳入 MCP 服务器能力", comment: ""), isOn: $pulseManager.includeMCPContext)
            Toggle(NSLocalizedString("纳入快捷指令能力", comment: ""), isOn: $pulseManager.includeShortcutContext)
            Toggle(NSLocalizedString("纳入最近外部结果", comment: ""), isOn: $pulseManager.includeRecentExternalResults)
            Toggle(NSLocalizedString("纳入公告与趋势信号", comment: ""), isOn: $pulseManager.includeTrendContext)

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
                    Label(NSLocalizedString("清空外部信号历史", comment: ""), systemImage: "trash")
                }
            }
        } header: {
            Text(NSLocalizedString("外部上下文", comment: ""))
        } footer: {
            Text(externalSourcesFooterText)
        }
    }

    private var externalSourcesFooterText: String {
        var parts: [String] = [
            "前两项会纳入可调用能力描述；“最近外部结果”会纳入快捷指令与 MCP 的最近结果；“公告与趋势信号”会纳入应用公告和已积累的趋势片段。"
        ]
        if pulseManager.externalSignalPreview.isEmpty {
            parts.append(NSLocalizedString("还没有积累到可复用的外部信号历史。快捷指令执行、MCP 输出和公告变化会逐步沉淀到这里。", comment: ""))
        }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var todayPulseSection: some View {
        if let run = pulseManager.todayRun {
            let visibleCards = run.visibleCards
            Section {
                if visibleCards.isEmpty {
                    Text(NSLocalizedString("这次生成的卡片都被你隐藏了。你可以重新生成一份新的每日脉冲。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleCards) { card in
                        cardView(card, runID: run.id)
                    }
                }
            } header: {
                Text(NSLocalizedString("今天的卡片", comment: ""))
            } footer: {
                Text(summaryText(for: run))
            }
        } else if pulseManager.isPreparingTodayPulse {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(NSLocalizedString("正在为你准备今天的每日脉冲", comment: ""), systemImage: "sparkles")
                        .etFont(.footnote.weight(.semibold))
                    Text(preparationStatusText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
            } header: {
                Text(NSLocalizedString("今天的卡片", comment: ""))
            }
        } else {
            Section {
                Text(NSLocalizedString("今天还没有生成新的每日脉冲。你可以立即生成，或者先写一点“明日想看什么”再回来。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(NSLocalizedString("今天的卡片", comment: ""))
            }
        }
    }

    private func cardView(_ card: DailyPulseCard, runID: UUID) -> some View {
        NavigationLink {
            DailyPulseCardDetailView(
                viewModel: viewModel,
                cardID: card.id,
                runID: runID,
                fallbackCard: card,
                statusMessage: $statusMessage
            )
        } label: {
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
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryText(for run: DailyPulseRun) -> String {
        let dateText = run.generatedAt.formatted(date: .abbreviated, time: .shortened)
        return String(format: NSLocalizedString("生成于 %@ · 可见卡片 %d/%d · 仅保留当天", comment: ""), dateText, run.visibleCards.count, run.cards.count)
    }

    private var preparationStatusText: String {
        if let startedAt = pulseManager.lastPreparationStartedAt {
            let timeText = startedAt.formatted(date: .omitted, time: .shortened)
            return String(format: NSLocalizedString("系统已在 %@ 开始准备今天这一期。你可以稍等片刻，或留在这里等待卡片刷新。", comment: ""), timeText)
        }
        return NSLocalizedString("系统正在根据你的聊天、记忆、反馈与外部上下文准备今天这一期。", comment: "")
    }

    private func historyTitle(for event: DailyPulseFeedbackEvent) -> String {
        switch event.action {
        case .liked:
            return String(format: NSLocalizedString("已喜欢 · %@", comment: ""), event.dayKey)
        case .disliked:
            return String(format: NSLocalizedString("已降权 · %@", comment: ""), event.dayKey)
        case .hidden:
            return String(format: NSLocalizedString("已隐藏 · %@", comment: ""), event.dayKey)
        case .saved:
            return String(format: NSLocalizedString("已保存为会话 · %@", comment: ""), event.dayKey)
        }
    }

    private func externalSignalTitle(for signal: DailyPulseExternalSignal) -> String {
        let prefix: String
        switch signal.source {
        case .shortcutResult:
            prefix = signal.isFailure ? NSLocalizedString("快捷指令失败", comment: "") : NSLocalizedString("快捷指令结果", comment: "")
        case .mcpOutput:
            prefix = NSLocalizedString("MCP 输出", comment: "")
        case .mcpError:
            prefix = NSLocalizedString("MCP 错误", comment: "")
        case .announcement:
            prefix = NSLocalizedString("公告/趋势", comment: "")
        }
        return String(format: NSLocalizedString("%@ · %@", comment: ""), prefix, signal.capturedAt.formatted(date: .abbreviated, time: .shortened))
    }

    @ViewBuilder
    private func feedbackBadge(for card: DailyPulseCard) -> some View {
        switch card.feedback {
        case .liked:
            Label(NSLocalizedString("已喜欢", comment: ""), systemImage: "heart.fill")
                .etFont(.caption2)
                .foregroundStyle(.pink)
        case .disliked:
            Label(NSLocalizedString("已降权", comment: ""), systemImage: "hand.thumbsdown.fill")
                .etFont(.caption2)
                .foregroundStyle(.orange)
        case .hidden:
            Label(NSLocalizedString("已隐藏", comment: ""), systemImage: "eye.slash.fill")
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        case .none:
            if card.savedSessionID != nil {
                Label(NSLocalizedString("已保存", comment: ""), systemImage: "bookmark.fill")
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

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.hour = deliveryCoordinator.reminderHour
                components.minute = deliveryCoordinator.reminderMinute
                return components.date ?? Date()
            },
            set: { newValue in
                let components = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: newValue)
                deliveryCoordinator.reminderHour = components.hour ?? deliveryCoordinator.reminderHour
                deliveryCoordinator.reminderMinute = components.minute ?? deliveryCoordinator.reminderMinute
            }
        )
    }
}

private struct DailyPulseCardDetailView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pulseManager = DailyPulseManager.shared

    let cardID: UUID
    let runID: UUID
    let fallbackCard: DailyPulseCard
    @Binding var statusMessage: String?

    private var card: DailyPulseCard {
        pulseManager.runs.first(where: { $0.id == runID })?.cards.first(where: { $0.id == cardID }) ?? fallbackCard
    }

    var body: some View {
        let currentCard = card
        let linkedTask = pulseManager.linkedTask(cardID: currentCard.id, runID: runID)

        List {
            Section(NSLocalizedString("内容", comment: "")) {
                Text(currentCard.summary)
                    .etFont(.footnote)

                Text(currentCard.whyRecommended)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                feedbackBadge(for: currentCard)
            }

            Section(NSLocalizedString("详情", comment: "")) {
                Markdown(currentCard.detailsMarkdown)
                    .etFont(.footnote)
                    .etDailyPulseMarkdownFontStyle(sampleText: currentCard.detailsMarkdown)
            }

            Section(NSLocalizedString("操作", comment: "")) {
                Button {
                    let hadSavedSession = currentCard.savedSessionID != nil
                    viewModel.continueDailyPulseCard(currentCard, from: runID)
                    statusMessage = hadSavedSession
                        ? NSLocalizedString("已打开这张卡片对应的会话，并填好继续追问。返回上一层即可继续。", comment: "")
                        : NSLocalizedString("已为这张卡片创建正式会话，并填好继续追问。返回上一层即可继续。", comment: "")
                } label: {
                    Label(NSLocalizedString("继续聊", comment: ""), systemImage: "arrow.up.right.circle")
                }

                Button {
                    if pulseManager.addTaskFromCard(cardID: currentCard.id, runID: runID) != nil {
                        statusMessage = linkedTask == nil ? NSLocalizedString("已加入 Pulse 任务。", comment: "") : NSLocalizedString("这张卡片已经在任务列表里。", comment: "")
                    }
                } label: {
                    Label(
                        linkedTask == nil ? NSLocalizedString("加入任务", comment: "") : NSLocalizedString("已在任务中", comment: ""),
                        systemImage: linkedTask == nil ? "checklist" : "checkmark.circle"
                    )
                }

                Button {
                    pulseManager.applyFeedback(.liked, cardID: currentCard.id, runID: runID)
                } label: {
                    Label(NSLocalizedString("喜欢", comment: ""), systemImage: currentCard.feedback == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }

                Button {
                    pulseManager.applyFeedback(.disliked, cardID: currentCard.id, runID: runID)
                } label: {
                    Label(NSLocalizedString("降权", comment: ""), systemImage: currentCard.feedback == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }

                Button(role: .destructive) {
                    pulseManager.applyFeedback(.hidden, cardID: currentCard.id, runID: runID)
                    dismiss()
                } label: {
                    Label(NSLocalizedString("隐藏这张卡片", comment: ""), systemImage: "eye.slash")
                }
            }
        }
        .navigationTitle(currentCard.title)
    }

    @ViewBuilder
    private func feedbackBadge(for card: DailyPulseCard) -> some View {
        switch card.feedback {
        case .liked:
            Label(NSLocalizedString("已喜欢", comment: ""), systemImage: "heart.fill")
                .etFont(.caption2)
                .foregroundStyle(.pink)
        case .disliked:
            Label(NSLocalizedString("已降权", comment: ""), systemImage: "hand.thumbsdown.fill")
                .etFont(.caption2)
                .foregroundStyle(.orange)
        case .hidden:
            Label(NSLocalizedString("已隐藏", comment: ""), systemImage: "eye.slash.fill")
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        case .none:
            if card.savedSessionID != nil {
                Label(NSLocalizedString("已保存", comment: ""), systemImage: "bookmark.fill")
                    .etFont(.caption2)
                    .foregroundStyle(.blue)
            }
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
