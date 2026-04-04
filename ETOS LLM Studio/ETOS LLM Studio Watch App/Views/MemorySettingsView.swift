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
    @State private var showClearConversationSummariesConfirmation = false
    @State private var showClearConversationProfileConfirmation = false
    @State private var isEditingConversationProfile = false
    @State private var conversationProfileDraft: String = ""
    @State private var conversationMemoryAlert: ConversationMemoryAlert?
    @AppStorage("memoryTopK") var memoryTopK: Int = 3
    @AppStorage("enableMemoryActiveRetrieval") private var enableMemoryActiveRetrieval: Bool = false
    @AppStorage("enableConversationMemoryAsync") private var enableConversationMemoryAsync: Bool = true
    @AppStorage("conversationMemoryRecentLimit") private var conversationMemoryRecentLimit: Int = 5
    @AppStorage("conversationMemoryRoundThreshold") private var conversationMemoryRoundThreshold: Int = 6
    @AppStorage("conversationMemorySummaryMinIntervalMinutes") private var conversationMemorySummaryMinIntervalMinutes: Int = 120
    @AppStorage("enableConversationProfileDailyUpdate") private var enableConversationProfileDailyUpdate: Bool = true

    private var embeddingModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedEmbeddingModel },
            set: { viewModel.setSelectedEmbeddingModel($0) }
        )
    }

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
            .confirmationDialog(
                "清空全部会话摘要？",
                isPresented: $showClearConversationSummariesConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    let removed = viewModel.clearAllConversationSummaries()
                    if removed > 0 {
                        conversationMemoryAlert = .init(title: "已清空会话摘要", message: "共清理 \(removed) 条摘要。")
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog(
                "清空用户画像？",
                isPresented: $showClearConversationProfileConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    do {
                        try viewModel.clearConversationUserProfile()
                        conversationMemoryAlert = .init(title: "已清空用户画像", message: "后续可重新生成或手动编辑。")
                    } catch {
                        conversationMemoryAlert = .init(title: "清空失败", message: error.localizedDescription)
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert(item: $conversationMemoryAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("好的"))
                )
            }
            .sheet(isPresented: $isEditingConversationProfile) {
                ConversationProfileEditorSheet(
                    initialText: conversationProfileDraft,
                    onSave: { newText in
                        do {
                            try viewModel.saveConversationUserProfile(content: newText)
                            conversationMemoryAlert = .init(title: "保存成功", message: "用户画像已更新。")
                        } catch {
                            conversationMemoryAlert = .init(title: "保存失败", message: error.localizedDescription)
                        }
                    }
                )
            }
            .task {
                viewModel.reloadConversationMemoryState()
            }
    }

    private var memoryListView: some View {
        List {
            Section {
                let options = viewModel.embeddingModelOptions
                if options.isEmpty {
                    Text("暂无可用模型，请先在“提供商与模型管理”中启用。")
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
                            Text("嵌入模型")
                            MarqueeText(
                                content: selectedEmbeddingModelLabel(in: options),
                                uiFont: .preferredFont(forTextStyle: .footnote)
                            )
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("嵌入模型")
            } footer: {
                Text("这里只列出支持嵌入能力的模型，记忆嵌入会调用所选模型。也可以在“提供商与模型管理 > 专用模型”中统一设置。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("检索数量 (Top K)")
                    Spacer()
                    TextField("数量", value: $memoryTopK, formatter: numberFormatter)
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
                Text("检索设置")
            } footer: {
                Text("设置为 0 表示跳过检索，直接注入全部记忆原文。默认 3。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("启用异步跨对话记忆", isOn: $enableConversationMemoryAsync)

                if enableConversationMemoryAsync {
                    HStack {
                        Text("注入最近摘要数")
                        Spacer()
                        TextField("5", value: $conversationMemoryRecentLimit, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onChange(of: conversationMemoryRecentLimit) { _, newValue in
                                conversationMemoryRecentLimit = max(1, newValue)
                            }
                    }

                    HStack {
                        Text("摘要触发轮次阈值")
                        Spacer()
                        TextField("6", value: $conversationMemoryRoundThreshold, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onChange(of: conversationMemoryRoundThreshold) { _, newValue in
                                conversationMemoryRoundThreshold = max(1, newValue)
                            }
                    }

                    HStack {
                        Text("摘要最小间隔(分钟)")
                        Spacer()
                        TextField("120", value: $conversationMemorySummaryMinIntervalMinutes, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onChange(of: conversationMemorySummaryMinIntervalMinutes) { _, newValue in
                                conversationMemorySummaryMinIntervalMinutes = max(0, newValue)
                            }
                    }

                    Toggle("用户画像每天自动更新一次", isOn: $enableConversationProfileDailyUpdate)

                    let options = viewModel.conversationSummaryModelOptions
                    if options.isEmpty {
                        Text("暂无可用聊天模型。")
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
                                Text("摘要专用模型")
                                MarqueeText(
                                    content: selectedConversationSummaryModelLabel(in: options),
                                    uiFont: .preferredFont(forTextStyle: .footnote)
                                )
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
            } header: {
                Text("跨对话记忆")
            } footer: {
                Text("会话摘要存入会话 JSON，用户画像存入 Memory/user_profile.json。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("会话摘要管理")) {
                let summaries = viewModel.conversationSessionSummaries
                if summaries.isEmpty {
                    Text("暂无会话摘要。")
                        .foregroundStyle(.secondary)
                        .etFont(.footnote)
                } else {
                    ForEach(summaries) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.sessionName)
                                .etFont(.footnote)
                            Text(item.summary)
                                .lineLimit(3)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            Text(item.updatedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel.deleteConversationSummary(for: item.sessionID)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }

                    Button(role: .destructive) {
                        showClearConversationSummariesConfirmation = true
                    } label: {
                        Label("清空全部会话摘要", systemImage: "trash.slash")
                    }
                }
            }

            Section(header: Text("用户画像")) {
                if let profile = viewModel.conversationUserProfile {
                    Text(profile.content)
                        .lineLimit(6)
                        .etFont(.footnote)
                    Text("更新时间：\(profile.updatedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Button("编辑用户画像") {
                        conversationProfileDraft = profile.content
                        isEditingConversationProfile = true
                    }
                    Button(role: .destructive) {
                        showClearConversationProfileConfirmation = true
                    } label: {
                        Label("清空用户画像", systemImage: "trash")
                    }
                } else {
                    Text("暂无用户画像。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    Button("新建用户画像") {
                        conversationProfileDraft = ""
                        isEditingConversationProfile = true
                    }
                }
            }
            
            Section(
                header: Text("数据维护"),
                footer: Text("将清空旧向量数据库，并按当前记忆重算所有嵌入。")
                    .etFont(.footnote)
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
                        .etFont(.caption2)
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
                                    .etFont(.footnote)
                                Text(memory.displayDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                    .etFont(.caption2)
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
                                    .etFont(.footnote)
                                    .foregroundColor(.secondary)
                                Text(memory.displayDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                    .etFont(.caption2)
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

    private func selectedEmbeddingModelLabel(in options: [RunnableModel]) -> String {
        guard let selected = viewModel.selectedEmbeddingModel,
              options.contains(where: { $0.id == selected.id }) else {
            return "未选择"
        }
        return "\(selected.model.displayName) | \(selected.provider.name)"
    }

    private func selectedConversationSummaryModelLabel(in options: [RunnableModel]) -> String {
        guard let selected = viewModel.selectedConversationSummaryModel,
              options.contains(where: { $0.id == selected.id }) else {
            return "未选择（跟随当前对话模型）"
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
                selectionRow(title: "未选择", isSelected: selectedEmbeddingModel == nil)
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
        .navigationTitle("嵌入模型")
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

/// 用于添加新记忆的表单视图
public struct AddMemorySheet: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    @State private var memoryContent: String = ""

    public init() {}

    public var body: some View {
        VStack {
            Text("添加新记忆")
                .etFont(.headline)
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

private struct ConversationProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        _draft = State(initialValue: initialText)
        self.onSave = onSave
    }

    var body: some View {
        List {
            Section("用户画像内容") {
                TextField("请输入画像内容", text: $draft.watchKeyboardNewlineBinding())
            }
            Section {
                Button("保存") {
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
