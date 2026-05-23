// ============================================================================
// KnowledgeBaseView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 知识库管理界面。手表端不选择本地文件，保留笔记与 URL 下载。
// ============================================================================

import SwiftUI
import Shared

struct KnowledgeBaseView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var store = KnowledgeBaseStore.shared
    @State private var isShowingNewBaseSheet = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if store.knowledgeBases.isEmpty {
                    Text(NSLocalizedString("还没有知识库。", comment: "知识库空状态"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.knowledgeBases) { base in
                        NavigationLink {
                            KnowledgeBaseDetailView(baseID: base.id)
                        } label: {
                            KnowledgeBaseRow(base: base)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("知识库", comment: "知识库列表分组"))
            } footer: {
                Text(NSLocalizedString("手表端可新建知识库、添加笔记，并通过 URL 下载资料。", comment: "watchOS 知识库说明"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    isShowingNewBaseSheet = true
                } label: {
                    Label(NSLocalizedString("新建知识库", comment: "新建知识库按钮"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(NSLocalizedString("知识库", comment: "知识库页标题"))
        .task {
            store.refresh()
        }
        .sheet(isPresented: $isShowingNewBaseSheet) {
            KnowledgeBaseEditorSheet(
                embeddingModels: viewModel.embeddingModelOptions,
                selectedEmbeddingModel: viewModel.selectedEmbeddingModel
            )
        }
        .alert(NSLocalizedString("知识库操作失败", comment: "知识库错误弹窗标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("好", comment: "确认按钮"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

private struct KnowledgeBaseRow: View {
    let base: KnowledgeBase

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(base.name)
                .etFont(.footnote.weight(.medium))
            Text(summary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let itemCount = String(format: NSLocalizedString("%d 个资料", comment: "知识库资料数量"), base.items.count)
        let chunkCount = String(format: NSLocalizedString("%d 个分块", comment: "知识库分块数量"), base.totalChunkCount)
        return "\(itemCount) · \(chunkCount)"
    }
}

private struct KnowledgeBaseEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = KnowledgeBaseStore.shared

    let embeddingModels: [RunnableModel]
    let selectedEmbeddingModel: RunnableModel?

    @State private var name = ""
    @State private var description = ""
    @State private var selectedEmbeddingModelID: String
    @State private var errorMessage: String?

    init(embeddingModels: [RunnableModel], selectedEmbeddingModel: RunnableModel?) {
        self.embeddingModels = embeddingModels
        self.selectedEmbeddingModel = selectedEmbeddingModel
        _selectedEmbeddingModelID = State(initialValue: selectedEmbeddingModel?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("名称", comment: "知识库名称输入框"), text: $name)
                    TextField(NSLocalizedString("描述", comment: "知识库描述输入框"), text: $description)
                }

                Section {
                    Picker(NSLocalizedString("嵌入模型", comment: "知识库嵌入模型选择"), selection: $selectedEmbeddingModelID) {
                        Text(NSLocalizedString("未选择", comment: "未选择选项")).tag("")
                        ForEach(embeddingModels) { runnable in
                            Text(runnable.model.displayName).tag(runnable.id)
                        }
                    }
                } footer: {
                    Text(NSLocalizedString("模型选择会随知识库保存。", comment: "watchOS 知识库嵌入模型说明"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(NSLocalizedString("新建知识库", comment: "新建知识库标题"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "取消按钮")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("创建", comment: "创建按钮")) {
                        Task { await create() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert(NSLocalizedString("创建失败", comment: "知识库创建失败标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("好", comment: "确认按钮"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var selectedRunnableModel: RunnableModel? {
        embeddingModels.first { $0.id == selectedEmbeddingModelID } ?? selectedEmbeddingModel
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func create() async {
        do {
            let model = selectedEmbeddingModelID.isEmpty ? nil : selectedRunnableModel
            _ = try await store.createKnowledgeBase(
                name: name,
                description: description,
                embeddingModelIdentifier: selectedEmbeddingModelID.isEmpty ? nil : selectedEmbeddingModelID,
                embeddingModelDisplayName: model?.model.displayName
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct KnowledgeBaseDetailView: View {
    @ObservedObject private var store = KnowledgeBaseStore.shared
    let baseID: UUID

    @State private var isShowingNoteSheet = false
    @State private var isShowingURLSheet = false
    @State private var errorMessage: String?

    private var base: KnowledgeBase? {
        store.knowledgeBases.first { $0.id == baseID }
    }

    var body: some View {
        List {
            if let base {
                Section {
                    LabeledContent(
                        NSLocalizedString("模型", comment: "watchOS 知识库模型标签"),
                        value: base.settings.embeddingModelDisplayName ?? NSLocalizedString("未选择", comment: "未选择值")
                    )
                    LabeledContent(
                        NSLocalizedString("分块", comment: "watchOS 知识库分块标签"),
                        value: String(format: NSLocalizedString("%d 字", comment: "watchOS 知识库分块值"), base.settings.chunkSize)
                    )
                }

                Section {
                    Button {
                        isShowingNoteSheet = true
                    } label: {
                        Label(NSLocalizedString("添加笔记", comment: "添加知识库笔记按钮"), systemImage: "note.text")
                    }

                    Button {
                        isShowingURLSheet = true
                    } label: {
                        Label(NSLocalizedString("从 URL 下载", comment: "添加知识库 URL 按钮"), systemImage: "link")
                    }
                } header: {
                    Text(NSLocalizedString("添加资料", comment: "知识库添加资料分组"))
                }

                Section {
                    if base.items.isEmpty {
                        Text(NSLocalizedString("还没有资料。", comment: "知识库资料空状态"))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(base.items) { item in
                            KnowledgeBaseItemRow(item: item)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("资料", comment: "知识库资料分组"))
                }

                Section {
                    Button(role: .destructive) {
                        Task { await delete(base) }
                    } label: {
                        Label(NSLocalizedString("删除知识库", comment: "删除知识库按钮"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(base?.name ?? NSLocalizedString("知识库", comment: "知识库页标题"))
        .task {
            store.refresh()
        }
        .sheet(isPresented: $isShowingNoteSheet) {
            KnowledgeBaseNoteSheet(baseID: baseID)
        }
        .sheet(isPresented: $isShowingURLSheet) {
            KnowledgeBaseURLSheet(baseID: baseID)
        }
        .alert(NSLocalizedString("知识库操作失败", comment: "知识库错误弹窗标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("好", comment: "确认按钮"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func delete(_ base: KnowledgeBase) async {
        do {
            try await store.deleteKnowledgeBase(id: base.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct KnowledgeBaseItemRow: View {
    let item: KnowledgeBaseSourceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .etFont(.footnote)
            Text(summary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            if !item.contentPreview.isEmpty {
                Text(item.contentPreview)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let status = item.status.localizedTitle
        let kind = item.kind.localizedTitle
        let chunkCount = String(format: NSLocalizedString("%d 个分块", comment: "知识库分块数量"), item.chunkCount)
        return "\(kind) · \(status) · \(chunkCount)"
    }
}

private struct KnowledgeBaseNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = KnowledgeBaseStore.shared
    let baseID: UUID

    @State private var title = ""
    @State private var content = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("标题", comment: "知识库笔记标题输入框"), text: $title)
                    TextField(NSLocalizedString("内容", comment: "知识库笔记内容输入框"), text: $content)
                }
            }
            .navigationTitle(NSLocalizedString("添加笔记", comment: "添加知识库笔记标题"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "取消按钮")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("添加", comment: "添加按钮")) {
                        Task { await add() }
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert(NSLocalizedString("添加失败", comment: "知识库添加失败标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("好", comment: "确认按钮"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func add() async {
        do {
            _ = try await store.addNote(to: baseID, title: title, content: content)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct KnowledgeBaseURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = KnowledgeBaseStore.shared
    let baseID: UUID

    @State private var urlText = ""
    @State private var title = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("URL", comment: "知识库 URL 输入框"), text: $urlText)
                    TextField(NSLocalizedString("标题（可选）", comment: "知识库 URL 标题输入框"), text: $title)
                } footer: {
                    Text(NSLocalizedString("会下载页面正文并保存到知识库。", comment: "watchOS 知识库 URL 导入说明"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(NSLocalizedString("从 URL 下载", comment: "知识库 URL 导入标题"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "取消按钮")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("下载", comment: "下载按钮")) {
                        Task { await download() }
                    }
                    .disabled(isImporting || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert(NSLocalizedString("下载失败", comment: "知识库 URL 下载失败标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("好", comment: "确认按钮"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func download() async {
        do {
            isImporting = true
            _ = try await store.importURL(to: baseID, urlText: urlText, title: title)
            isImporting = false
            dismiss()
        } catch {
            isImporting = false
            errorMessage = error.localizedDescription
        }
    }
}
