// ============================================================================
// DailyPulseView.swift
// ============================================================================
// watchOS 每日脉冲视图
//
// 功能特性:
// - 展示每日脉冲卡片与核心状态
// - 支持手动生成、自动补生成、关注焦点输入
// - 支持卡片反馈、保存为会话与继续聊天
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
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                Toggle("自动补生成", isOn: $pulseManager.autoGenerateEnabled)

                if let run = pulseManager.primaryRun {
                    Text(run.headline)
                        .font(.footnote.weight(.semibold))
                    Text(summaryText(for: run))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if pulseManager.isPreparingTodayPulse {
                    Text("今天这一期正在准备中。")
                        .font(.footnote.weight(.semibold))
                    Text(preparationStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("还没有每日脉冲记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await pulseManager.generateNow()
                        if pulseManager.lastErrorMessage == nil {
                            statusMessage = "已尝试生成。"
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
            }

            Section {
                Toggle("晨间提醒", isOn: $deliveryCoordinator.reminderEnabled)
                if deliveryCoordinator.reminderEnabled {
                    DatePicker(
                        "提醒时间",
                        selection: reminderTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    if notificationCenter.authorizationStatus == .denied {
                        Text("通知权限未开启")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("主动送达")
            } footer: {
                Text(deliveryCoordinator.reminderStatusText)
            }

            Section {
                TextField("例如：下一步要做什么", text: $pulseManager.focusText)
                if !pulseManager.focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(role: .destructive) {
                        pulseManager.focusText = ""
                    } label: {
                        Label("清空", systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text("当前关注")
            }

            Section {
                TextField("明天想看什么", text: $pulseManager.tomorrowCurationText)
                if let pending = pulseManager.pendingCuration {
                    Text("目标日：\(pending.targetDayKey)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("明日策展")
            }

            Section {
                if pulseManager.pendingTasks.isEmpty && pulseManager.completedTasksPreview.isEmpty {
                    Text("还没有 Pulse 任务。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pulseManager.pendingTasks.prefix(3)) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title)
                                .font(.footnote.weight(.semibold))
                            if !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(task.details)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button {
                                    pulseManager.toggleTaskCompletion(id: task.id)
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                }
                                .tint(.green)

                                Button(role: .destructive) {
                                    pulseManager.removeTask(id: task.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if !pulseManager.completedTasksPreview.isEmpty {
                        ForEach(pulseManager.completedTasksPreview) { task in
                            Label(task.title, systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button(role: .destructive) {
                            pulseManager.clearCompletedTasks()
                        } label: {
                            Label("清理已完成", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Pulse 任务")
            }

            Section {
                if pulseManager.feedbackHistoryPreview.isEmpty {
                    Text("还没有反馈历史。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pulseManager.feedbackHistoryPreview.prefix(3)) { event in
                        Text(historyTitle(for: event))
                            .font(.caption2)
                    }

                    NavigationLink {
                        DailyPulseFeedbackHistoryView()
                    } label: {
                        Label("查看完整历史", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                }
            } header: {
                Text("反馈历史")
            }

            Section {
                Toggle("MCP 能力", isOn: $pulseManager.includeMCPContext)
                Toggle("快捷指令能力", isOn: $pulseManager.includeShortcutContext)
                Toggle("最近外部结果", isOn: $pulseManager.includeRecentExternalResults)
                Toggle("公告与趋势", isOn: $pulseManager.includeTrendContext)

                if pulseManager.externalSignalPreview.isEmpty {
                    Text("还没有外部信号历史。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pulseManager.externalSignalPreview.prefix(3)) { signal in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(externalSignalTitle(for: signal))
                                .font(.caption2.weight(.semibold))
                            Text(signal.preview)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        pulseManager.clearExternalSignals()
                    } label: {
                        Label("清空信号历史", systemImage: "trash")
                    }
                }
            } header: {
                Text("外部上下文")
            }

            if let run = pulseManager.todayRun {
                let visibleCards = run.visibleCards
                Section {
                    if visibleCards.isEmpty {
                        Text("这次卡片都被隐藏了，可以重新生成。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleCards) { card in
                            cardView(card, runID: run.id)
                        }
                    }
                } header: {
                    Text("今天的卡片")
                }
            } else if pulseManager.isPreparingTodayPulse {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("正在准备今天这一期")
                            .font(.footnote.weight(.semibold))
                        Text(preparationStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView()
                    }
                } header: {
                    Text("今天的卡片")
                }
            } else {
                Section {
                    Text("今天还没有新的每日脉冲。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("今天的卡片")
                }
            }

        }
        .navigationTitle("每日脉冲")
        .task {
            await pulseManager.generateIfNeeded()
            pulseManager.markTodayRunViewed()
            await notificationCenter.refreshAuthorizationStatus()
        }
        .onChange(of: pulseManager.todayRun?.dayKey) { _, _ in
            pulseManager.markTodayRunViewed()
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

    private func cardView(_ card: DailyPulseCard, runID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.headline)
            Text(card.summary)
                .font(.footnote)
            Text(card.whyRecommended)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                toggleExpansion(for: card.id)
            } label: {
                Label(
                    expandedCardIDs.contains(card.id) ? "收起详情" : "展开详情",
                    systemImage: expandedCardIDs.contains(card.id) ? "chevron.up.circle" : "doc.text"
                )
            }
            .buttonStyle(.bordered)

            if expandedCardIDs.contains(card.id) {
                Markdown(card.detailsMarkdown)
                    .font(.footnote)
                    .padding(.top, 4)
            }

            if card.savedSessionID != nil {
                Label("已保存为会话", systemImage: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

            Button {
                if viewModel.saveDailyPulseCard(card, from: runID) != nil {
                    statusMessage = card.savedSessionID == nil ? "已保存为会话。" : "已打开已保存会话。"
                }
            } label: {
                Label(card.savedSessionID == nil ? "保存为会话" : "打开会话", systemImage: card.savedSessionID == nil ? "square.and.arrow.down" : "bubble.left.and.bubble.right")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.continueDailyPulseCard(card, from: runID)
                statusMessage = "已写入聊天输入框，返回上一层即可继续。"
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
            .buttonStyle(.bordered)

            HStack {
                Button {
                    pulseManager.applyFeedback(.liked, cardID: card.id, runID: runID)
                } label: {
                    Image(systemName: card.feedback == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .tint(.pink)

                Button {
                    pulseManager.applyFeedback(.disliked, cardID: card.id, runID: runID)
                } label: {
                    Image(systemName: card.feedback == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .tint(.orange)

                Button(role: .destructive) {
                    pulseManager.applyFeedback(.hidden, cardID: card.id, runID: runID)
                } label: {
                    Image(systemName: "eye.slash")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func expansionBinding(for cardID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedCardIDs.contains(cardID) },
            set: { isExpanded in
                if isExpanded {
                    expandedCardIDs.insert(cardID)
                } else {
                    expandedCardIDs.remove(cardID)
                }
            }
        )
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
        return "\(dateText) · \(run.visibleCards.count)/\(run.cards.count) 张可见 · 仅保留当天"
    }

    private var preparationStatusText: String {
        if let startedAt = pulseManager.lastPreparationStartedAt {
            let timeText = startedAt.formatted(date: .omitted, time: .shortened)
            return "\(timeText) 已开始准备。"
        }
        return "系统正在整理今天这一期。"
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
            return "已保存 · \(event.dayKey)"
        }
    }

    private func externalSignalTitle(for signal: DailyPulseExternalSignal) -> String {
        switch signal.source {
        case .shortcutResult:
            return signal.isFailure ? "快捷指令失败" : "快捷指令结果"
        case .mcpOutput:
            return "MCP 输出"
        case .mcpError:
            return "MCP 错误"
        case .announcement:
            return "公告/趋势"
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
