// ============================================================================
// MemorySettingsView.swift
// ============================================================================
// MemorySettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct MemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingMemory = false
    @State private var isReembeddingMemories = false
    @State private var showReembedConfirmation = false
    @State private var reembedAlert: MemoryReembedAlert?
    @State private var editingMemory: MemoryItem?
    @AppStorage("memoryTopK") private var memoryTopK: Int = 3
    @AppStorage("enableMemoryActiveRetrieval") private var enableMemoryActiveRetrieval: Bool = false
    
    private var embeddingModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedEmbeddingModel },
            set: { viewModel.setSelectedEmbeddingModel($0) }
        )
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
    
    private var activeEmbeddingProgress: MemoryEmbeddingProgress? {
        viewModel.memoryEmbeddingProgress
    }
    
    private var isEmbeddingBusy: Bool {
        isReembeddingMemories || viewModel.isMemoryEmbeddingInProgress
    }
    
    private func embeddingProgressTitle(for progress: MemoryEmbeddingProgress) -> String {
        switch (progress.kind, progress.phase) {
        case (.reembedAll, .running):
            return NSLocalizedString("正在重新生成嵌入…", comment: "Memory re-embedding in progress title")
        case (.reembedAll, .completed):
            return NSLocalizedString("重新嵌入完成", comment: "Memory re-embedding completed title")
        case (.reembedAll, .failed):
            return NSLocalizedString("重新嵌入失败", comment: "Memory re-embedding failed title")
        case (.reconcilePending, .running):
            return NSLocalizedString("正在补偿缺失嵌入…", comment: "Memory embedding reconcile in progress title")
        case (.reconcilePending, .completed):
            return NSLocalizedString("补偿嵌入已完成", comment: "Memory embedding reconcile completed title")
        case (.reconcilePending, .failed):
            return NSLocalizedString("补偿嵌入部分失败", comment: "Memory embedding reconcile partially failed title")
        @unknown default:
            return NSLocalizedString("记忆嵌入状态更新中", comment: "Fallback memory embedding status title")
        }
    }
    
    private func embeddingProgressColor(for progress: MemoryEmbeddingProgress) -> Color {
        switch progress.phase {
        case .running:
            return .secondary
        case .completed:
            return .green
        case .failed:
            return .orange
        @unknown default:
            return .secondary
        }
    }
    
    var body: some View {
        Form {
            Section {
                let options = viewModel.embeddingModelOptions
                if options.isEmpty {
                    Text(NSLocalizedString("暂无可用模型，请先在“提供商与模型管理”中启用。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        EmbeddingModelSelectionView(
                            embeddingModels: options,
                            selectedEmbeddingModel: embeddingModelBinding
                        )
                    } label: {
                        HStack {
                            Text(NSLocalizedString("嵌入模型", comment: ""))
                            MarqueeText(
                                content: selectedEmbeddingModelLabel(in: options),
                                uiFont: .preferredFont(forTextStyle: .body)
                            )
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("嵌入模型", comment: ""))
            } footer: {
                Text(NSLocalizedString("这里只列出支持嵌入能力的模型，记忆嵌入请求会使用所选模型发送。也可以在“提供商与模型管理 > 专用模型”中统一设置。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(NSLocalizedString("检索数量 (Top K)", comment: "")) {
                    TextField(NSLocalizedString("0 表示不限制", comment: ""), value: $memoryTopK, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: memoryTopK) { _, newValue in
                            memoryTopK = max(0, newValue)
                        }
                }
                if memoryTopK > 0 {
                    Toggle(
                        NSLocalizedString("主动检索", comment: "Active retrieval toggle title"),
                        isOn: $enableMemoryActiveRetrieval
                    )
                    Text(
                        NSLocalizedString(
                            "开启后会向 AI 暴露记忆检索工具，AI 可按向量或关键词主动检索，并指定返回数量。",
                            comment: "Active retrieval toggle description"
                        )
                    )
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(NSLocalizedString("检索设置", comment: ""))
            } footer: {
                Text(NSLocalizedString("设置为 0 表示跳过检索，直接把所有记忆原文注入上下文。默认为 3。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    showReembedConfirmation = true
                } label: {
                    Label(NSLocalizedString("重新生成全部嵌入", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isEmbeddingBusy)
                
                if let progress = activeEmbeddingProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(embeddingProgressTitle(for: progress))
                            .etFont(.caption)
                            .foregroundStyle(embeddingProgressColor(for: progress))
                        
                        ProgressView(
                            value: Double(progress.processedMemories),
                            total: Double(max(progress.totalMemories, 1))
                        )
                        
                        Text(
                            String(
                                format: NSLocalizedString("解析进度 %d / %d", comment: ""),
                                progress.processedMemories,
                                progress.totalMemories
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        
                        if progress.phase == .running,
                           let preview = progress.currentMemoryPreview,
                           !preview.isEmpty {
                            Text(
                                String(
                                    format: NSLocalizedString("正在处理：%@", comment: ""),
                                    preview
                                )
                            )
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        
                        if progress.phase == .failed,
                           let message = progress.errorMessage,
                           !message.isEmpty {
                            Text(message)
                                .etFont(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("数据维护", comment: ""))
            } footer: {
                Text(NSLocalizedString("会清理旧的向量数据库并为所有记忆重新生成嵌入。完成后历史检索将使用最新数据。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section {
                let activeMemories = viewModel.memories.filter { !$0.isArchived }
                if activeMemories.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("暂无激活的记忆", comment: ""),
                        systemImage: "brain.head.profile",
                        description: Text(NSLocalizedString("发送对话时可以让 AI 通过工具主动写入新的记忆。", comment: ""))
                    )
                } else {
                    ForEach(activeMemories) { memory in
                        Button {
                            editingMemory = memory
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(memory.content)
                                    .lineLimit(2)
                                Text(memory.displayDate.formatted(date: .abbreviated, time: .shortened))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let index = viewModel.memories.firstIndex(where: { $0.id == memory.id }) {
                                    Task {
                                        await viewModel.deleteMemories(at: IndexSet(integer: index))
                                    }
                                }
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await viewModel.archiveMemory(memory)
                                }
                            } label: {
                                Label(NSLocalizedString("归档", comment: ""), systemImage: "archivebox")
                            }
                            .tint(.orange)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("激活的记忆", comment: ""))
            } footer: {
                Text(NSLocalizedString("这些记忆会参与检索并发送给模型。左滑删除，右滑归档。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section {
                let archivedMemories = viewModel.memories.filter { $0.isArchived }
                if archivedMemories.isEmpty {
                    Text(NSLocalizedString("没有被归档的记忆。", comment: ""))
                        .foregroundStyle(.secondary)
                        .etFont(.footnote)
                } else {
                    ForEach(archivedMemories) { memory in
                        Button {
                            editingMemory = memory
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(memory.content)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                                Text(memory.displayDate.formatted(date: .abbreviated, time: .shortened))
                                    .etFont(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let index = viewModel.memories.firstIndex(where: { $0.id == memory.id }) {
                                    Task {
                                        await viewModel.deleteMemories(at: IndexSet(integer: index))
                                    }
                                }
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await viewModel.unarchiveMemory(memory)
                                }
                            } label: {
                                Label(NSLocalizedString("恢复", comment: ""), systemImage: "arrow.uturn.backward")
                            }
                            .tint(.green)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("归档的记忆", comment: ""))
            } footer: {
                Text(NSLocalizedString("这些记忆已被归档，不会参与检索。左滑删除，右滑恢复。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("记忆库管理", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isAddingMemory = true
                } label: {
                    Label(NSLocalizedString("添加记忆", comment: ""), systemImage: "plus")
                }
            }
        }
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
        .sheet(isPresented: $isAddingMemory) {
            NavigationStack {
                AddMemorySheet()
                    .environmentObject(viewModel)
            }
        }
        .sheet(item: $editingMemory) { memory in
            NavigationStack {
                MemoryEditView(memory: memory)
                    .environmentObject(viewModel)
            }
        }
        .task {
            viewModel.reloadConversationMemoryState()
        }
    }
    
    private func deleteItems(at offsets: IndexSet) {
        Task {
            await viewModel.deleteMemories(at: offsets)
        }
    }

    private func selectedEmbeddingModelLabel(in options: [RunnableModel]) -> String {
        guard let selected = viewModel.selectedEmbeddingModel,
              options.contains(where: { $0.id == selected.id }) else {
            return NSLocalizedString("未选择", comment: "")
        }
        return "\(selected.model.displayName) | \(selected.provider.name)"
    }
    
    private func triggerFullReembed() {
        guard !isReembeddingMemories else { return }
        isReembeddingMemories = true
        
        Task {
            do {
                let summary = try await viewModel.reembedAllMemories()
                await MainActor.run {
                    reembedAlert = MemoryReembedAlert.success(summary: summary)
                    isReembeddingMemories = false
                }
            } catch {
                await MainActor.run {
                    reembedAlert = MemoryReembedAlert.failure(message: error.localizedDescription)
                    isReembeddingMemories = false
                }
            }
        }
    }
}

private struct EmbeddingModelSelectionView: View {
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

struct ConversationMemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showClearConversationSummariesConfirmation = false
    @State private var showClearConversationProfileConfirmation = false
    @State private var isEditingConversationProfile = false
    @State private var conversationProfileDraft: String = ""
    @State private var conversationMemoryAlert: ConversationMemoryAlert?
    @AppStorage("conversationMemoryRecentLimit") private var conversationMemoryRecentLimit: Int = 5
    @AppStorage("conversationMemoryRoundThreshold") private var conversationMemoryRoundThreshold: Int = 6
    @AppStorage("conversationMemorySummaryMinIntervalMinutes") private var conversationMemorySummaryMinIntervalMinutes: Int = 120
    @AppStorage("enableConversationProfileDailyUpdate") private var enableConversationProfileDailyUpdate: Bool = true

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
                    TextField("5", value: $conversationMemoryRecentLimit, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: conversationMemoryRecentLimit) { _, newValue in
                            conversationMemoryRecentLimit = max(1, newValue)
                        }
                }

                LabeledContent(NSLocalizedString("摘要触发轮次阈值", comment: "")) {
                    TextField("6", value: $conversationMemoryRoundThreshold, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: conversationMemoryRoundThreshold) { _, newValue in
                            conversationMemoryRoundThreshold = max(1, newValue)
                        }
                }

                LabeledContent(NSLocalizedString("摘要最小间隔(分钟)", comment: "")) {
                    TextField("120", value: $conversationMemorySummaryMinIntervalMinutes, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: conversationMemorySummaryMinIntervalMinutes) { _, newValue in
                            conversationMemorySummaryMinIntervalMinutes = max(0, newValue)
                        }
                }

                Toggle(NSLocalizedString("用户画像每天自动更新一次", comment: ""), isOn: $enableConversationProfileDailyUpdate)

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

private struct MemoryReembedAlert: Identifiable {
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
