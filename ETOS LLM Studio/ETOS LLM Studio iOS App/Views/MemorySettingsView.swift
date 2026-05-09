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
    @EnvironmentObject private var appConfig: AppConfigStore
    @State private var isAddingMemory = false
    @State private var isReembeddingMemories = false
    @State private var showReembedConfirmation = false
    @State private var reembedAlert: MemoryReembedAlert?
    @State private var editingMemory: MemoryItem?
    
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
                Text(NSLocalizedString("这里只列出主用途为嵌入的模型，记忆嵌入请求会使用所选模型发送。也可以在“提供商与模型管理 > 专用模型”中统一设置。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(NSLocalizedString("检索数量 (Top K)", comment: "")) {
                    TextField(NSLocalizedString("0 表示关闭检索", comment: ""), value: $appConfig.memoryTopK, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: appConfig.memoryTopK) { _, newValue in
                            appConfig.memoryTopK = max(0, newValue)
                        }
                }
                if appConfig.memoryTopK > 0 {
                    Toggle(
                        NSLocalizedString("主动检索", comment: "Active retrieval toggle title"),
                        isOn: $appConfig.enableMemoryActiveRetrieval
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
                Text(NSLocalizedString("如果开启检索，可能会导致上下文缓存命中率极低。若想关闭检索，请将 Top K 设置为 0。默认 3。", comment: ""))
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
