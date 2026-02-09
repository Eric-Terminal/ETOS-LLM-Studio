// ============================================================================
// MemorySettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了记忆库管理的主视图。
// 用户可以在此查看、添加、删除和编辑他们的长期记忆。
// ============================================================================

import SwiftUI
import Foundation
import Shared

public struct MemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingMemory = false
    @State private var isReembeddingMemories = false
    @State private var showReembedConfirmation = false
    @State private var reembedAlert: MemoryReembedAlert?
    @AppStorage("memoryTopK") var memoryTopK: Int = 3

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

    public init() {}

    public var body: some View {
        memoryListView
            .navigationTitle("记忆库管理")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { isAddingMemory = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingMemory) {
                AddMemorySheet()
                    .environmentObject(viewModel)
            }
            .confirmationDialog(
                "重新嵌入全部记忆？",
                isPresented: $showReembedConfirmation,
                titleVisibility: .visible
            ) {
                Button("重新嵌入", role: .destructive) {
                    triggerFullReembed()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除旧的 SQLite 向量数据库，并根据当前记忆重新生成嵌入。")
            }
            .alert(item: $reembedAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("好的"))
                )
            }
    }

    private var memoryListView: some View {
        List {
            Section {
                let options = viewModel.embeddingModelOptions
                if options.isEmpty {
                    Text("暂无可用模型，请先在“提供商与模型管理”中启用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("嵌入模型", selection: embeddingModelBinding) {
                        Text("未选择").tag(Optional<RunnableModel>.none)
                        ForEach(options) { runnable in
                            Text("\(runnable.model.displayName) | \(runnable.provider.name)")
                                .tag(Optional<RunnableModel>.some(runnable))
                        }
                    }
                }
            } header: {
                Text("嵌入模型")
            } footer: {
                Text("列出当前配置的所有模型，记忆嵌入会调用所选模型。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("检索数量 (Top K)")
                    Spacer()
                    TextField("数量", value: $memoryTopK, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } header: {
                Text("检索设置")
            } footer: {
                Text("设置为 0 表示跳过检索，直接注入全部记忆原文。默认 3。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section(
                header: Text("数据维护"),
                footer: Text("将清空旧向量数据库，并按当前记忆重算所有嵌入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Button(role: .destructive) {
                    showReembedConfirmation = true
                } label: {
                    Label("重新生成全部嵌入", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isEmbeddingBusy)
                
                if let progress = activeEmbeddingProgress {
                    Text(embeddingProgressTitle(for: progress))
                        .font(.caption2)
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
                    .font(.caption2)
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    
                    if progress.phase == .failed,
                       let message = progress.errorMessage,
                       !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section(header: Text(NSLocalizedString("激活的记忆", comment: ""))) {
                let activeMemories = viewModel.memories.filter { !$0.isArchived }
                if activeMemories.isEmpty {
                    Text(NSLocalizedString("还没有激活的记忆。", comment: ""))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(activeMemories) { memory in
                        NavigationLink(destination: MemoryEditView(memory: memory).environmentObject(viewModel)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memory.content)
                                    .lineLimit(2)
                                    .font(.footnote)
                                Text(memory.displayDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    if let index = viewModel.memories.firstIndex(where: { $0.id == memory.id }) {
                                        await viewModel.deleteMemories(at: IndexSet(integer: index))
                                    }
                                }
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
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
            }
            
            Section(header: Text(NSLocalizedString("归档的记忆", comment: ""))) {
                let archivedMemories = viewModel.memories.filter { $0.isArchived }
                if archivedMemories.isEmpty {
                    Text(NSLocalizedString("没有被归档的记忆。", comment: ""))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(archivedMemories) { memory in
                        NavigationLink(destination: MemoryEditView(memory: memory).environmentObject(viewModel)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memory.content)
                                    .lineLimit(2)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Text(memory.displayDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    if let index = viewModel.memories.firstIndex(where: { $0.id == memory.id }) {
                                        await viewModel.deleteMemories(at: IndexSet(integer: index))
                                    }
                                }
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
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
            }
        }
    }
    
    private func deleteItems(at offsets: IndexSet) {
        Task {
            await viewModel.deleteMemories(at: offsets)
        }
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

/// 用于添加新记忆的表单视图
public struct AddMemorySheet: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    @State private var memoryContent: String = ""

    public init() {}

    public var body: some View {
        VStack {
            Text("添加新记忆")
                .font(.headline)
                .padding()

            TextField("输入记忆内容...", text: $memoryContent.watchKeyboardNewlineBinding())
                .padding()

            Button("保存") {
                Task {
                    await viewModel.addMemory(content: memoryContent)
                    dismiss()
                }
            }
            .disabled(memoryContent.isEmpty)
        }
    }
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
            return "重新嵌入完成"
        case .failure:
            return "重新嵌入失败"
        }
    }
    
    var message: String {
        switch kind {
        case .success(let summary):
            return String(
                format: NSLocalizedString("已处理 %d 条记忆，生成 %d 个分块。", comment: ""),
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

// 预览
struct MemorySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        MemorySettingsView()
            .environmentObject(ChatViewModel())
    }
}
