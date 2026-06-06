// ============================================================================
// MemorySettingsSupport.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 记忆设置视图的模型选择、添加记忆、跨对话记忆与提示弹窗。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct EmbeddingModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let embeddingModels: [RunnableModel]
    @Binding var selectedEmbeddingModel: RunnableModel?

    var body: some View {
        List {
            Button {
                select(nil)
            } label: {
                selectionRow(title: NSLocalizedString("未选择", comment: ""), isSelected: selectedEmbeddingModel == nil)
            }

            ForEach(embeddingModels) { runnable in
                Button {
                    select(runnable)
                } label: {
                    selectionRow(
                        title: runnable.model.displayName,
                        subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                        isSelected: selectedEmbeddingModel?.id == runnable.id
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("嵌入模型", comment: ""))
    }

    private func select(_ model: RunnableModel?) {
        selectedEmbeddingModel = model
        dismiss()
    }

    @ViewBuilder
    private func selectionRow(title: String, subtitle: String? = nil, isSelected: Bool) -> some View {
        MarqueeTitleSubtitleSelectionRow(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            subtitleUIFont: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
        )
    }
}

struct AddMemorySheet: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var memoryContent: String = ""

    var body: some View {
        Form {
            Section(NSLocalizedString("记忆内容", comment: "")) {
                TextField(NSLocalizedString("输入要记住的信息…", comment: ""), text: $memoryContent, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle(NSLocalizedString("添加记忆", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    Task {
                        await viewModel.addMemory(content: memoryContent)
                        dismiss()
                    }
                }
                .disabled(memoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private enum MemoryReembedRowStatus: Equatable {
    case pending
    case running
    case succeeded
    case failed(String)
}

struct MemoryDataMaintenanceView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isReembeddingAll = false
    @State private var runningMemoryIDs = Set<UUID>()
    @State private var rowStatuses: [UUID: MemoryReembedRowStatus] = [:]
    @State private var showReembedConfirmation = false
    @State private var reembedAlert: MemoryReembedAlert?
    @ObservedObject private var appConfig = AppConfigStore.shared

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var memories: [MemoryItem] {
        viewModel.memories.sorted { $0.displayDate > $1.displayDate }
    }

    private var normalizedConcurrencyLimit: Int {
        max(1, appConfig.memoryReembeddingConcurrencyLimit)
    }

    private var isReembeddingBusy: Bool {
        isReembeddingAll || !runningMemoryIDs.isEmpty || viewModel.isMemoryEmbeddingInProgress
    }

    var body: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    showReembedConfirmation = true
                } label: {
                    Label(NSLocalizedString("重新生成全部嵌入", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isReembeddingBusy || memories.isEmpty)

                LabeledContent(NSLocalizedString("并发数量", comment: "Memory reembedding concurrency limit field")) {
                    TextField("1", value: $appConfig.memoryReembeddingConcurrencyLimit, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .disabled(isReembeddingBusy)
                        .onChange(of: appConfig.memoryReembeddingConcurrencyLimit) { _, newValue in
                            appConfig.memoryReembeddingConcurrencyLimit = max(1, newValue)
                        }
                }
            } header: {
                Text(NSLocalizedString("重新嵌入", comment: "Memory reembedding maintenance section"))
            } footer: {
                Text(NSLocalizedString("会清理旧的向量数据库，并按当前记忆重新生成嵌入。并发数量会自动保存。", comment: "Memory reembedding maintenance footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if memories.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("暂无记忆", comment: "Memory maintenance empty title"),
                        systemImage: "brain.head.profile",
                        description: Text(NSLocalizedString("添加记忆后可在这里重新生成嵌入。", comment: "Memory maintenance empty description"))
                    )
                } else {
                    ForEach(memories) { memory in
                        let status = status(for: memory)
                        if case .failed = status {
                            Button {
                                retry(memory)
                            } label: {
                                memoryRow(memory, status: status)
                            }
                            .buttonStyle(.plain)
                            .disabled(isReembeddingBusy)
                        } else {
                            memoryRow(memory, status: status)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("记忆", comment: "Memory maintenance memory section"))
            } footer: {
                Text(NSLocalizedString("重新嵌入完成后会显示勾选标记；失败的记忆可点按单独重试。", comment: "Memory maintenance memory footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("数据维护", comment: ""))
        .confirmationDialog(NSLocalizedString("重新嵌入全部记忆？", comment: ""),
            isPresented: $showReembedConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("重新嵌入", comment: ""), role: .destructive) {
                triggerFullReembed()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("此操作会删除旧的 SQLite 向量数据库，并基于当前记忆原文重新生成嵌入。", comment: ""))
        }
        .alert(item: $reembedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("好的", comment: "")))
            )
        }
    }

    private func memoryRow(_ memory: MemoryItem, status: MemoryReembedRowStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(memory.content)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(memory.displayDate.formatted(date: .abbreviated, time: .shortened))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    if memory.isArchived {
                        Text(NSLocalizedString("已归档", comment: "Archived memory status"))
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if case .failed(let message) = status {
                    Text(message)
                        .etFont(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusIndicator(for: status)
                .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusIndicator(for status: MemoryReembedRowStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        case .failed:
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func status(for memory: MemoryItem) -> MemoryReembedRowStatus {
        if runningMemoryIDs.contains(memory.id) {
            return .running
        }
        return rowStatuses[memory.id] ?? .pending
    }

    private func triggerFullReembed() {
        guard !isReembeddingBusy else { return }
        let targetMemories = memories
        guard !targetMemories.isEmpty else { return }
        let targetIDs = Set(targetMemories.map(\.id))
        let limit = normalizedConcurrencyLimit
        isReembeddingAll = true
        runningMemoryIDs = targetIDs
        for id in targetIDs {
            rowStatuses[id] = .running
        }

        Task {
            do {
                let results = try await viewModel.reembedAllMemoriesDetailed(concurrencyLimit: limit) { result in
                    await MainActor.run {
                        applyReembeddingResult(result)
                    }
                }
                await MainActor.run {
                    finishFullReembed(results: results, targetIDs: targetIDs)
                }
            } catch {
                await MainActor.run {
                    markRemainingAsFailed(targetIDs: targetIDs, message: error.localizedDescription)
                    reembedAlert = MemoryReembedAlert.failure(message: error.localizedDescription)
                    isReembeddingAll = false
                }
            }
        }
    }

    private func retry(_ memory: MemoryItem) {
        guard !isReembeddingBusy else { return }
        runningMemoryIDs.insert(memory.id)
        rowStatuses[memory.id] = .running

        Task {
            do {
                let results = try await viewModel.reembedMemories(
                    withIDs: [memory.id],
                    concurrencyLimit: 1
                ) { result in
                    await MainActor.run {
                        applyReembeddingResult(result)
                    }
                }
                await MainActor.run {
                    if results.isEmpty {
                        runningMemoryIDs.remove(memory.id)
                    }
                }
            } catch {
                await MainActor.run {
                    runningMemoryIDs.remove(memory.id)
                    rowStatuses[memory.id] = .failed(error.localizedDescription)
                    reembedAlert = MemoryReembedAlert.failure(message: error.localizedDescription)
                }
            }
        }
    }

    private func applyReembeddingResult(_ result: MemoryReembeddingItemResult) {
        runningMemoryIDs.remove(result.memoryID)
        if result.succeeded {
            rowStatuses[result.memoryID] = .succeeded
        } else {
            rowStatuses[result.memoryID] = .failed(result.errorMessage ?? NSLocalizedString("未知错误", comment: ""))
        }
    }

    private func finishFullReembed(results: [MemoryReembeddingItemResult], targetIDs: Set<UUID>) {
        for id in targetIDs {
            if runningMemoryIDs.contains(id) {
                runningMemoryIDs.remove(id)
            }
            if rowStatuses[id] == .running {
                rowStatuses[id] = .pending
            }
        }

        let failedResults = results.filter { !$0.succeeded }
        if failedResults.isEmpty {
            let summary = MemoryReembeddingSummary(
                processedMemories: results.count,
                chunkCount: results.reduce(0) { $0 + $1.chunkCount }
            )
            reembedAlert = MemoryReembedAlert.success(summary: summary)
        } else {
            reembedAlert = MemoryReembedAlert.failure(
                message: String(
                    format: NSLocalizedString("%d 条记忆重嵌入失败，可点击失败项单独重试。", comment: "Memory reembedding partial failure alert"),
                    failedResults.count
                )
            )
        }
        isReembeddingAll = false
    }

    private func markRemainingAsFailed(targetIDs: Set<UUID>, message: String) {
        for id in targetIDs where runningMemoryIDs.contains(id) {
            runningMemoryIDs.remove(id)
            rowStatuses[id] = .failed(message)
        }
    }
}

struct ConversationMemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showClearConversationSummariesConfirmation = false
    @State private var showClearConversationProfileConfirmation = false
    @State private var isEditingConversationProfile = false
    @State private var conversationProfileDraft: String = ""
    @State private var conversationMemoryAlert: ConversationMemoryAlert?
    @ObservedObject private var appConfig = AppConfigStore.shared

    private var conversationSummaryModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedConversationSummaryModel },
            set: { viewModel.setSelectedConversationSummaryModel($0) }
        )
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(NSLocalizedString("注入最近摘要数", comment: "")) {
                    TextField("5", value: $appConfig.conversationMemoryRecentLimit, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: appConfig.conversationMemoryRecentLimit) { _, newValue in
                            appConfig.conversationMemoryRecentLimit = max(1, newValue)
                        }
                }

                LabeledContent(NSLocalizedString("摘要触发轮次阈值", comment: "")) {
                    TextField("6", value: $appConfig.conversationMemoryRoundThreshold, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: appConfig.conversationMemoryRoundThreshold) { _, newValue in
                            appConfig.conversationMemoryRoundThreshold = max(1, newValue)
                        }
                }

                LabeledContent(NSLocalizedString("摘要最小间隔(分钟)", comment: "")) {
                    TextField("120", value: $appConfig.conversationMemorySummaryMinIntervalMinutes, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: appConfig.conversationMemorySummaryMinIntervalMinutes) { _, newValue in
                            appConfig.conversationMemorySummaryMinIntervalMinutes = max(0, newValue)
                        }
                }

                Toggle(NSLocalizedString("用户画像每天自动更新一次", comment: ""), isOn: $appConfig.enableConversationProfileDailyUpdate)

                let options = viewModel.conversationSummaryModelOptions
                if options.isEmpty {
                    Text(NSLocalizedString("暂无可用聊天模型，无法配置摘要专用模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        EmbeddingModelSelectionView(
                            embeddingModels: options,
                            selectedEmbeddingModel: conversationSummaryModelBinding
                        )
                    } label: {
                        HStack {
                            Text(NSLocalizedString("摘要专用模型", comment: ""))
                            MarqueeText(
                                content: selectedConversationSummaryModelLabel(in: options),
                                uiFont: .preferredFont(forTextStyle: .body)
                            )
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("跨对话记忆", comment: ""))
            } footer: {
                Text(NSLocalizedString("这里管理跨对话记忆的触发门槛、注入数量和画像日更策略。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                let conversationSummaries = viewModel.conversationSessionSummaries
                if conversationSummaries.isEmpty {
                    Text(NSLocalizedString("暂无会话摘要。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(conversationSummaries) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.sessionName)
                                    .lineLimit(1)
                                    .etFont(.headline)
                                Spacer()
                                Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.summary)
                                .lineLimit(3)
                                .etFont(.footnote)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.deleteConversationSummary(for: item.sessionID)
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                    }

                    Button(role: .destructive) {
                        showClearConversationSummariesConfirmation = true
                    } label: {
                        Label(NSLocalizedString("清空全部会话摘要", comment: ""), systemImage: "trash.slash")
                    }
                }
            } header: {
                Text(NSLocalizedString("会话摘要管理", comment: ""))
            } footer: {
                Text(NSLocalizedString("这里展示跨会话注入用的摘要，可按条删除或一键清空。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let profile = viewModel.conversationUserProfile {
                    Text(profile.content)
                        .lineLimit(6)
                    Text(String(format: NSLocalizedString("更新时间：%@", comment: ""), profile.updatedAt.formatted(date: .abbreviated, time: .shortened)))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("编辑用户画像", comment: "")) {
                        conversationProfileDraft = profile.content
                        isEditingConversationProfile = true
                    }
                    Button(role: .destructive) {
                        showClearConversationProfileConfirmation = true
                    } label: {
                        Label(NSLocalizedString("清空用户画像", comment: ""), systemImage: "trash")
                    }
                } else {
                    Text(NSLocalizedString("暂无用户画像。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("新建用户画像", comment: "")) {
                        conversationProfileDraft = ""
                        isEditingConversationProfile = true
                    }
                }
            } header: {
                Text(NSLocalizedString("用户画像", comment: ""))
            } footer: {
                Text(NSLocalizedString("用户画像用于补充稳定偏好和长期背景。即使自动更新关闭，你仍可在这里手动编辑。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("跨对话记忆与画像", comment: ""))
        .confirmationDialog(NSLocalizedString("清空全部会话摘要？", comment: ""),
            isPresented: $showClearConversationSummariesConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清空", comment: ""), role: .destructive) {
                let removed = viewModel.clearAllConversationSummaries()
                if removed > 0 {
                    conversationMemoryAlert = .init(
                        title: NSLocalizedString("已清空会话摘要", comment: ""),
                        message: String(format: NSLocalizedString("共清理 %d 条摘要。", comment: ""), removed)
                    )
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
        .confirmationDialog(NSLocalizedString("清空用户画像？", comment: ""),
            isPresented: $showClearConversationProfileConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清空", comment: ""), role: .destructive) {
                do {
                    try viewModel.clearConversationUserProfile()
                    conversationMemoryAlert = .init(title: NSLocalizedString("已清空用户画像", comment: ""), message: NSLocalizedString("后续可重新生成或手动编辑。", comment: ""))
                } catch {
                    conversationMemoryAlert = .init(title: NSLocalizedString("清空失败", comment: ""), message: error.localizedDescription)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
        .alert(item: $conversationMemoryAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("好的", comment: "")))
            )
        }
        .sheet(isPresented: $isEditingConversationProfile) {
            NavigationStack {
                ConversationProfileEditorSheet(
                    initialText: conversationProfileDraft,
                    onSave: { newText in
                        do {
                            try viewModel.saveConversationUserProfile(content: newText)
                            conversationMemoryAlert = .init(title: NSLocalizedString("保存成功", comment: ""), message: NSLocalizedString("用户画像已更新。", comment: ""))
                        } catch {
                            conversationMemoryAlert = .init(title: NSLocalizedString("保存失败", comment: ""), message: error.localizedDescription)
                        }
                    }
                )
            }
        }
        .task {
            viewModel.reloadConversationMemoryState()
        }
    }

    private func selectedConversationSummaryModelLabel(in options: [RunnableModel]) -> String {
        guard let selected = viewModel.selectedConversationSummaryModel,
              options.contains(where: { $0.id == selected.id }) else {
            return NSLocalizedString("未选择（跟随当前对话模型）", comment: "")
        }
        return "\(selected.model.displayName) | \(selected.provider.name)"
    }
}

private struct ConversationProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        _draft = State(initialValue: initialText)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("用户画像内容", comment: "")) {
                TextEditor(text: $draft)
                    .frame(minHeight: 220)
            }
        }
        .navigationTitle(NSLocalizedString("编辑用户画像", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    onSave(draft)
                    dismiss()
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct ConversationMemoryAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct MemoryReembedAlert: Identifiable {
    enum Kind {
        case success(MemoryReembeddingSummary)
        case failure(String)
    }

    let id = UUID()
    let kind: Kind

    var title: String {
        switch kind {
        case .success:
            return NSLocalizedString("重新嵌入完成", comment: "")
        case .failure:
            return NSLocalizedString("重新嵌入失败", comment: "")
        }
    }

    var message: String {
        switch kind {
        case .success(let summary):
            return String(
                format: NSLocalizedString("共处理 %d 条记忆，生成 %d 个分块。", comment: ""),
                summary.processedMemories,
                summary.chunkCount
            )
        case .failure(let message):
            return message
        }
    }

    static func success(summary: MemoryReembeddingSummary) -> MemoryReembedAlert {
        MemoryReembedAlert(kind: .success(summary))
    }

    static func failure(message: String) -> MemoryReembedAlert {
        MemoryReembedAlert(kind: .failure(message))
    }
}
