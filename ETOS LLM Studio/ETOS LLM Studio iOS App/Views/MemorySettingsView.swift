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
    @State private var editingMemory: MemoryItem?
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
                LabeledContent(NSLocalizedString("检索数量 (Top K)", comment: "")) {
                    TextField(NSLocalizedString("0 表示关闭检索", comment: ""), value: $appConfig.memoryTopK, formatter: numberFormatter)
                        .keyboardType(.numberPad)
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

            Section {
                NavigationLink {
                    MemoryDataMaintenanceView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("数据维护", comment: ""), systemImage: "wrench.and.screwdriver")
                }
            } header: {
                Text(NSLocalizedString("数据维护", comment: ""))
            } footer: {
                Text(NSLocalizedString("进入后可重新生成全部嵌入，并查看每条记忆的处理状态。", comment: ""))
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

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "记忆检索介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "记忆检索介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "记忆检索介绍卡片展开按钮"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString(details, comment: "记忆检索介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "记忆检索介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
