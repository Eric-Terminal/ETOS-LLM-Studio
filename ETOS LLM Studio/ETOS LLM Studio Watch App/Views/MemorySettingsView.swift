// ============================================================================
// MemorySettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了记忆库管理的主视图。
// 用户可以在此查看、添加、删除和编辑他们的记忆系统。
// ============================================================================

import SwiftUI
import Foundation
import Shared

public struct MemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingMemory = false
    @State private var isShowingRetrievalIntroDetails = false
    @ObservedObject private var appConfig = AppConfigStore.shared

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

    public init() {}

    public var body: some View {
        memoryListView
            .navigationTitle(NSLocalizedString("记忆库管理", comment: ""))
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
            .task {
                viewModel.reloadConversationMemoryState()
            }
    }

    private var memoryListView: some View {
        List {
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
                                uiFont: .preferredFont(forTextStyle: .footnote)
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
                Text(NSLocalizedString("这里只列出主用途为嵌入的模型，记忆嵌入会调用所选模型。也可以在“提供商与模型管理 > 专用模型”中统一设置。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                settingsIntroCard(
                    title: "记忆检索",
                    summary: "控制记忆如何被选中，并决定发送给模型时附带哪些信息。",
                    details: """
                    检索数量 (Top K)
                    • 大于 0 时，会按当前消息检索最相关的记忆。
                    • 设置为 0 时，跳过向量检索，直接发送所有激活记忆原文。
                    • 默认 3。

                    主动检索
                    • 开启后会向 AI 暴露 search_memory 工具。
                    • AI 可按向量或关键词主动检索，并指定返回数量。
                    • 主动检索可能降低上下文缓存命中率。

                    发送更新时间
                    • 开启时，每条记忆会附带最近更新时间。
                    • 关闭时，只发送记忆条目内容。
                    """,
                    isExpanded: $isShowingRetrievalIntroDetails
                )
                HStack {
                    Text(NSLocalizedString("检索数量 (Top K)", comment: ""))
                    Spacer()
                    TextField(NSLocalizedString("数量", comment: ""), value: $appConfig.memoryTopK, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: appConfig.memoryTopK) { _, newValue in
                            appConfig.memoryTopK = max(0, newValue)
                        }
                }
                Toggle(
                    NSLocalizedString("发送更新时间", comment: "Memory send update time toggle title"),
                    isOn: $appConfig.memorySendUpdateTime
                )
                if appConfig.memoryTopK > 0 {
                    Toggle(
                        NSLocalizedString("主动检索", comment: "Active retrieval toggle title"),
                        isOn: $viewModel.enableMemoryActiveRetrieval
                    )
                }
            } header: {
                Text(NSLocalizedString("检索设置", comment: ""))
            } footer: {
                Text(NSLocalizedString("Top K 为 0 时不执行检索；默认 3。", comment: "Memory retrieval settings footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(
                header: Text(NSLocalizedString("数据维护", comment: "")),
                footer: Text(NSLocalizedString("进入后可重新生成全部嵌入，并查看每条记忆的处理状态。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                NavigationLink {
                    MemoryDataMaintenanceView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("数据维护", comment: ""), systemImage: "wrench.and.screwdriver")
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
            return NSLocalizedString("未选择", comment: "")
        }
        return "\(selected.model.displayName) | \(selected.provider.name)"
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "记忆检索介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "记忆检索介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "记忆检索介绍卡片展开按钮"))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "记忆检索介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

// 预览
struct MemorySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        MemorySettingsView()
            .environmentObject(ChatViewModel())
    }
}
