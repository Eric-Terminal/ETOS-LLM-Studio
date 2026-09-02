// ============================================================================
// DailyPulseView.swift
// ============================================================================
// iOS 每日脉冲视图
//
// 功能特性:
// - 展示每日脉冲卡片列表与详情
// - 提供手动生成、自动补生成开关与关注焦点输入
// - 支持卡片反馈、加入任务与继续聊天
// ============================================================================

import SwiftUI
import MarkdownUI
import ETOSCore

struct DailyPulseView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var pulseManager = DailyPulseManager.shared
    @ObservedObject private var deliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared

    @State private var statusMessage: String?
    @State private var notificationCardTarget: DailyPulseCardNavigationTarget?
    @State private var didHandleInitialCardTarget = false
    private let initialCardTarget: DailyPulseCardNavigationTarget?

    init(initialRunID: UUID? = nil, initialCardID: UUID? = nil) {
        if let initialRunID, let initialCardID {
            self.initialCardTarget = DailyPulseCardNavigationTarget(
                runID: initialRunID,
                cardID: initialCardID
            )
        } else {
            self.initialCardTarget = nil
        }
    }

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
            pulseAvailabilitySection
        }
        .navigationTitle(NSLocalizedString("每日脉冲", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .alert(NSLocalizedString("每日脉冲", comment: ""), isPresented: alertBinding) {
            Button(NSLocalizedString("知道了", comment: ""), role: .cancel) {
                statusMessage = nil
                pulseManager.clearError()
            }
        } message: {
            Text(pulseManager.lastErrorMessage ?? statusMessage ?? "")
        }
        .task {
            await pulseManager.generateIfNeeded()
            pulseManager.markTodayRunViewed()
            await notificationCenter.refreshAuthorizationStatus()
            openInitialCardIfNeeded()
        }
        .onChange(of: pulseManager.todayRun?.dayKey) { _, _ in
            pulseManager.markTodayRunViewed()
            openInitialCardIfNeeded()
        }
        .navigationDestination(item: $notificationCardTarget) { target in
            notificationCardDetail(for: target)
        }
        .guideSettingsPageContext(
            id: "daily-pulse",
            title: NSLocalizedString("每日脉冲", comment: "每日脉冲向导上下文标题"),
            documents: [GuideDocumentReference(id: "daily-pulse", title: "Daily Pulse")],
            settings: dailyPulseGuideSettings
        )
    }

    private var dailyPulseGuideSettings: [GuidePageSetting] {
        [
            .bool(
                "enabled",
                label: NSLocalizedString("启用每日脉冲", comment: "每日脉冲向导字段"),
                get: { pulseManager.isDailyPulseEnabled },
                set: { pulseManager.isDailyPulseEnabled = $0 }
            ),
            .bool(
                "auto_generate_on_first_open",
                label: NSLocalizedString("每日首次打开自动补生成", comment: "每日脉冲向导字段"),
                get: { pulseManager.autoGenerateEnabled },
                set: { pulseManager.autoGenerateEnabled = $0 }
            ),
            .bool(
                "scheduled_delivery_enabled",
                label: NSLocalizedString("定时送达", comment: "每日脉冲向导字段"),
                get: { deliveryCoordinator.reminderEnabled },
                set: { deliveryCoordinator.reminderEnabled = $0 }
            ),
            .json(
                "card_count",
                label: NSLocalizedString("卡片数量", comment: "每日脉冲向导字段"),
                schema: .dictionary([
                    "type": .string("integer"),
                    "minimum": .int(1)
                ]),
                get: { .int(deliveryCoordinator.deliveryTimes.count) },
                normalize: { value in
                    guard case .int(let count) = value, count >= 1 else {
                        throw GuideError.invalidToolArguments
                    }
                    return .int(count)
                },
                set: { value in
                    guard case .int(let count) = value else { throw GuideError.invalidToolArguments }
                    deliveryCoordinator.setCardCount(count)
                }
            ),
            .readOnly(
                "delivery_times",
                label: NSLocalizedString("各卡片送达时间", comment: "每日脉冲向导字段"),
                value: {
                    .array(deliveryCoordinator.deliveryTimes.map { time in
                        .dictionary([
                            "id": .string(time.id.uuidString.lowercased()),
                            "time": .string(time.timeText)
                        ])
                    })
                }
            ),
            .string(
                "focus",
                label: NSLocalizedString("当前关注焦点", comment: "每日脉冲向导字段"),
                get: { pulseManager.focusText },
                set: { pulseManager.focusText = $0 }
            ),
            .string(
                "tomorrow_curation",
                label: NSLocalizedString("明日想看什么", comment: "每日脉冲向导字段"),
                get: { pulseManager.tomorrowCurationText },
                set: { pulseManager.tomorrowCurationText = $0 }
            ),
            .bool(
                "include_mcp_context",
                label: NSLocalizedString("纳入 MCP 服务器能力", comment: "每日脉冲向导字段"),
                get: { pulseManager.includeMCPContext },
                set: { pulseManager.includeMCPContext = $0 }
            ),
            .bool(
                "include_shortcut_context",
                label: NSLocalizedString("纳入快捷指令能力", comment: "每日脉冲向导字段"),
                get: { pulseManager.includeShortcutContext },
                set: { pulseManager.includeShortcutContext = $0 }
            ),
            .bool(
                "include_recent_external_results",
                label: NSLocalizedString("纳入最近外部结果", comment: "每日脉冲向导字段"),
                get: { pulseManager.includeRecentExternalResults },
                set: { pulseManager.includeRecentExternalResults = $0 }
            ),
            .bool(
                "include_trend_context",
                label: NSLocalizedString("纳入公告与趋势信号", comment: "每日脉冲向导字段"),
                get: { pulseManager.includeTrendContext },
                set: { pulseManager.includeTrendContext = $0 }
            ),
            .readOnly(
                "status",
                label: NSLocalizedString("当前生成状态", comment: "每日脉冲向导字段"),
                value: {
                    .dictionary([
                        "is_generating": .bool(pulseManager.isGenerating),
                        "has_today_run": .bool(pulseManager.todayRun != nil),
                        "has_tomorrow_run": .bool(pulseManager.tomorrowRun != nil),
                        "pending_task_count": .int(pulseManager.pendingTasks.count)
                    ])
                }
            )
        ]
    }

    private var generationSection: some View {
        Section {
            Toggle(NSLocalizedString("每日首次打开自动补生成", comment: ""), isOn: $pulseManager.autoGenerateEnabled)

            if let run = pulseManager.latestRun {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.headline)
                        .etFont(.headline)
                    Text(summaryText(for: run))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if pulseManager.isPreparingTodayPulse {
                VStack(alignment: .leading, spacing: 8) {
                    Label(NSLocalizedString("今天这一期正在准备中", comment: ""), systemImage: "hourglass")
                        .etFont(.headline)
                    Text(preparationStatusText)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Text(NSLocalizedString("还没有每日脉冲记录。你可以先手动生成一份今天的主动情报卡片。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if pulseManager.tomorrowRun != nil {
                Label(NSLocalizedString("明日脉冲已预先准备", comment: "Daily Pulse tomorrow run ready status"), systemImage: "calendar.badge.checkmark")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else if pulseManager.isPreparingTomorrowPulse {
                Label(NSLocalizedString("正在提前准备明日脉冲", comment: "Daily Pulse tomorrow run preparing status"), systemImage: "calendar.badge.clock")
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
            .disabled(pulseManager.isGenerating || !pulseManager.isDailyPulseEnabled)
        } header: {
            Text(NSLocalizedString("生成", comment: ""))
        } footer: {
            Text(
                String(
                    format: NSLocalizedString("共生成 %d 张卡片；每张卡片都有独立送达时间，相同时间的卡片会一起生成但分别通知。", comment: "Daily Pulse generation footer with per-card delivery time"),
                    deliveryCoordinator.totalCardCount
                )
            )
        }
    }

    private var pulseAvailabilitySection: some View {
        Section {
            Toggle(NSLocalizedString("启用每日脉冲", comment: "Daily Pulse enabled toggle"), isOn: $pulseManager.isDailyPulseEnabled)
        } footer: {
            Text(NSLocalizedString("关闭后不会再生成新的每日脉冲；已有卡片、任务和反馈记录仍会保留。", comment: "Daily Pulse enabled toggle footer"))
        }
    }

    private var deliverySection: some View {
        Section {
            Toggle(NSLocalizedString("定时送达", comment: "Daily Pulse scheduled delivery toggle"), isOn: $deliveryCoordinator.reminderEnabled)

            if deliveryCoordinator.reminderEnabled {
                Stepper(value: cardCountBinding, step: 1) {
                    Text(
                        String(
                            format: NSLocalizedString("%d 张卡片", comment: "Daily Pulse configured card count"),
                            deliveryCoordinator.deliveryTimes.count
                        )
                    )
                }

                ForEach(Array(deliveryCoordinator.deliveryTimes.enumerated()), id: \.element.id) { index, deliveryTime in
                    NavigationLink {
                        DailyPulseDeliveryTimeEditor(deliveryTimeID: deliveryTime.id)
                    } label: {
                        HStack {
                            Text(
                                String(
                                    format: NSLocalizedString("第 %d 张卡片", comment: "Daily Pulse card delivery row"),
                                    index + 1
                                )
                            )
                            Spacer()
                            Text(deliveryTime.timeText)
                                .monospacedDigit()
                        }
                    }
                }

                if notificationCenter.authorizationStatus == .denied {
                    Button(NSLocalizedString("打开系统通知设置", comment: "")) {
                        viewModel.openSystemNotificationSettings()
                    }
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
                    .etFont(.footnote)
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
            Text(NSLocalizedString("这里更像 Pulse 的“明天想看什么”。下一次到达目标日期并生成每日脉冲时，会优先纳入这段策展输入。", comment: ""))
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
                            .etFont(.subheadline.weight(.medium))
                        if !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(task.details)
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                pulseManager.toggleTaskCompletion(id: task.id)
                            } label: {
                                Label(NSLocalizedString("标记完成", comment: ""), systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                pulseManager.removeTask(id: task.id)
                            } label: {
                                Label(NSLocalizedString("移除", comment: ""), systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !pulseManager.completedTasksPreview.isEmpty {
                    ForEach(pulseManager.completedTasksPreview) { task in
                        Label(task.title, systemImage: "checkmark.circle.fill")
                            .etFont(.footnote)
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
                            .etFont(.subheadline.weight(.medium))
                        Text(event.cardTitle)
                            .etFont(.footnote)
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
                            .etFont(.subheadline.weight(.medium))
                        Text(signal.preview)
                            .etFont(.footnote)
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
            NSLocalizedString("前两项会纳入可调用能力描述；“最近外部结果”会纳入快捷指令 / MCP 的最近结果与历史信号；“公告与趋势信号”则会纳入应用当前公告与已积累的趋势片段。", comment: "Daily Pulse external context footer")
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
                VStack(alignment: .leading, spacing: 8) {
                    Label(NSLocalizedString("正在为你准备今天的每日脉冲", comment: ""), systemImage: "sparkles")
                        .etFont(.subheadline.weight(.medium))
                    Text(preparationStatusText)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
                .padding(.vertical, 6)
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
                cardID: card.id,
                runID: runID,
                fallbackCard: card,
                statusMessage: $statusMessage
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(card.title)
                        .etFont(.headline)
                    Spacer()
                    feedbackBadge(for: card)
                }

                Text(card.summary)
                    .etFont(.subheadline)
                    .foregroundStyle(.primary)

                Text(card.whyRecommended)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func openInitialCardIfNeeded() {
        guard !didHandleInitialCardTarget,
              notificationCardTarget == nil,
              let initialCardTarget,
              pulseManager.card(cardID: initialCardTarget.cardID, runID: initialCardTarget.runID) != nil else {
            return
        }
        didHandleInitialCardTarget = true
        notificationCardTarget = initialCardTarget
    }

    @ViewBuilder
    private func notificationCardDetail(for target: DailyPulseCardNavigationTarget) -> some View {
        if let card = pulseManager.card(cardID: target.cardID, runID: target.runID) {
            DailyPulseCardDetailView(
                cardID: card.id,
                runID: target.runID,
                fallbackCard: card,
                statusMessage: $statusMessage
            )
        } else {
            Text(NSLocalizedString("这张每日脉冲卡片暂时不可用。", comment: "Daily Pulse notification card unavailable"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func feedbackBadge(for card: DailyPulseCard) -> some View {
        switch card.feedback {
        case .liked:
            Label(NSLocalizedString("已喜欢", comment: ""), systemImage: "heart.fill")
                .etFont(.caption)
                .foregroundStyle(.pink)
        case .disliked:
            Label(NSLocalizedString("已降权", comment: ""), systemImage: "hand.thumbsdown.fill")
                .etFont(.caption)
                .foregroundStyle(.orange)
        case .hidden:
            Label(NSLocalizedString("已隐藏", comment: ""), systemImage: "eye.slash.fill")
                .etFont(.caption)
                .foregroundStyle(.secondary)
        case .none:
            if card.savedSessionID != nil {
                Label(NSLocalizedString("已保存", comment: ""), systemImage: "bookmark.fill")
                    .etFont(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    private func summaryText(for run: DailyPulseRun) -> String {
        let dateText = run.generatedAt.formatted(date: .abbreviated, time: .shortened)
        return String(
            format: NSLocalizedString("适用于 %@ · 生成于 %@ · 可见卡片 %d/%d · 仅展示当天", comment: "Daily Pulse target day and generation time summary"),
            run.dayKey,
            dateText,
            run.visibleCards.count,
            run.cards.count
        )
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

    private var cardCountBinding: Binding<Int> {
        Binding(
            get: { deliveryCoordinator.deliveryTimes.count },
            set: { deliveryCoordinator.setCardCount($0) }
        )
    }

}

private struct DailyPulseDeliveryTimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var deliveryCoordinator = DailyPulseDeliveryCoordinator.shared

    let deliveryTimeID: UUID
    @State private var timeDraft = ""
    @State private var isTimeInvalid = false

    private var deliveryTime: DailyPulseDeliveryTime? {
        deliveryCoordinator.deliveryTimes.first(where: { $0.id == deliveryTimeID })
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("送达时间", comment: "Daily Pulse delivery time section")) {
                TextField(
                    NSLocalizedString("送达时间", comment: "Daily Pulse delivery time field"),
                    text: $timeDraft
                )
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .keyboardType(.numbersAndPunctuation)
                .onChange(of: timeDraft) { _, value in
                    validateTimeDraft(value)
                }
                .onSubmit {
                    saveTimeDraft()
                }

                if isTimeInvalid {
                    Text(NSLocalizedString("时间格式不正确，请输入 00:00-23:59。", comment: "Daily Pulse delivery time invalid input"))
                        .etFont(.caption)
                        .foregroundStyle(.red)
                }
            }

            if deliveryCoordinator.deliveryTimes.count > 1 {
                Section {
                    Button(role: .destructive) {
                        if deliveryCoordinator.removeCard(id: deliveryTimeID) {
                            dismiss()
                        }
                    } label: {
                        Label(NSLocalizedString("删除卡片", comment: "Daily Pulse delete card button"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("编辑卡片", comment: "Daily Pulse edit card title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            timeDraft = deliveryTime?.timeText ?? ""
        }
        .onDisappear {
            saveTimeDraft()
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "daily-pulse-delivery-time-\(deliveryTimeID.uuidString.lowercased())"),
            title: NSLocalizedString("编辑卡片", comment: "每日脉冲送达时间向导上下文标题"),
            documents: [GuideDocumentReference(id: "daily-pulse", title: "Daily Pulse")],
            settings: deliveryTimeGuideSettings
        )
    }

    private var deliveryTimeGuideSettings: [GuidePageSetting] {
        [
            .readOnly(
                "delivery_time_id",
                label: NSLocalizedString("送达时间 ID", comment: "每日脉冲送达时间向导字段"),
                value: { .string(deliveryTimeID.uuidString.lowercased()) }
            ),
            .json(
                "time",
                label: NSLocalizedString("送达时间", comment: "每日脉冲送达时间向导字段"),
                schema: .dictionary([
                    "type": .string("string"),
                    "description": .string("24 小时制 HH:mm")
                ]),
                get: { .string(deliveryTime?.timeText ?? timeDraft) },
                normalize: { value in
                    guard case .string(let text) = value,
                          let components = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: text) else {
                        throw GuideError.invalidToolArguments
                    }
                    return .string(String(format: "%02d:%02d", components.hour, components.minute))
                },
                set: { value in
                    guard case .string(let text) = value,
                          let components = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: text),
                          deliveryCoordinator.updateDeliveryTime(
                            id: deliveryTimeID,
                            hour: components.hour,
                            minute: components.minute
                          ) else {
                        throw GuideError.invalidToolArguments
                    }
                    timeDraft = String(format: "%02d:%02d", components.hour, components.minute)
                    isTimeInvalid = false
                }
            )
        ]
    }

    private func validateTimeDraft(_ input: String) {
        isTimeInvalid = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: input) == nil
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveTimeDraft() {
        guard !isTimeInvalid,
              let components = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: timeDraft),
              deliveryCoordinator.updateDeliveryTime(
                id: deliveryTimeID,
                hour: components.hour,
                minute: components.minute
              ) else { return }
        timeDraft = deliveryTime?.timeText ?? timeDraft
    }
}

private struct DailyPulseCardNavigationTarget: Identifiable, Hashable {
    let runID: UUID
    let cardID: UUID

    var id: String {
        "\(runID.uuidString)-\(cardID.uuidString)"
    }
}

private struct DailyPulseCardDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
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
                    .etFont(.body)

                Text(currentCard.whyRecommended)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                feedbackBadge(for: currentCard)
            }

            Section(NSLocalizedString("详情", comment: "")) {
                Markdown(currentCard.detailsMarkdown)
                    .etFont(.subheadline)
                    .etDailyPulseMarkdownFontStyle(sampleText: currentCard.detailsMarkdown)
            }

            Section(NSLocalizedString("操作", comment: "")) {
                Button {
                    let hadSavedSession = currentCard.savedSessionID != nil
                    viewModel.continueDailyPulseCard(currentCard, from: runID)
                    statusMessage = hadSavedSession
                        ? NSLocalizedString("已打开这张卡片对应的会话，并为你填好继续追问。", comment: "")
                        : NSLocalizedString("已为这张卡片创建正式会话，并为你填好继续追问。", comment: "")
                } label: {
                    Label(NSLocalizedString("继续聊", comment: ""), systemImage: "arrow.up.right.circle")
                }

                Button {
                    if pulseManager.addTaskFromCard(cardID: currentCard.id, runID: runID) != nil {
                        statusMessage = linkedTask == nil ? NSLocalizedString("已加入 Pulse 任务。", comment: "") : NSLocalizedString("这张卡片已经在 Pulse 任务列表里。", comment: "")
                    }
                } label: {
                    Label(
                        linkedTask == nil ? NSLocalizedString("加入 Pulse 任务", comment: "") : NSLocalizedString("已在 Pulse 任务中", comment: ""),
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
                    Label(NSLocalizedString("暂不感兴趣", comment: ""), systemImage: currentCard.feedback == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
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
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func feedbackBadge(for card: DailyPulseCard) -> some View {
        switch card.feedback {
        case .liked:
            Label(NSLocalizedString("已喜欢", comment: ""), systemImage: "heart.fill")
                .foregroundStyle(.pink)
        case .disliked:
            Label(NSLocalizedString("已降权", comment: ""), systemImage: "hand.thumbsdown.fill")
                .foregroundStyle(.orange)
        case .hidden:
            Label(NSLocalizedString("已隐藏", comment: ""), systemImage: "eye.slash.fill")
                .foregroundStyle(.secondary)
        case .none:
            if card.savedSessionID != nil {
                Label(NSLocalizedString("已保存", comment: ""), systemImage: "bookmark.fill")
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
