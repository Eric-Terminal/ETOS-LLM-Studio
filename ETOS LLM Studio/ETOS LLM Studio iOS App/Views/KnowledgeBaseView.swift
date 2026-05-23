// ============================================================================
// KnowledgeBaseView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 知识库管理界面：创建知识库，添加笔记、URL 和本地文件资料。
// ============================================================================

import SwiftUI
import Shared
import UniformTypeIdentifiers

struct KnowledgeBaseView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var store = KnowledgeBaseStore.shared
    @State private var isShowingNewBaseSheet = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                settingsIntroCard
            }

            Section {
                if store.knowledgeBases.isEmpty {
                    Text(NSLocalizedString("还没有知识库。", comment: "知识库空状态"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.knowledgeBases) { base in
                        NavigationLink {
                            KnowledgeBaseDetailView(baseID: base.id)
                        } label: {
                            KnowledgeBaseRow(base: base)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await delete(base) }
                            } label: {
                                Label(NSLocalizedString("删除", comment: "删除按钮"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("知识库", comment: "知识库列表分组"))
            } footer: {
                Text(NSLocalizedString("资料会先解析并写入独立知识库数据库，后续会继续接入嵌入队列、向量检索和聊天引用。", comment: "知识库列表说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("知识库", comment: "知识库页标题"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingNewBaseSheet = true
                } label: {
                    Label(NSLocalizedString("新建知识库", comment: "新建知识库按钮"), systemImage: "plus")
                }
            }
        }
        .task {
            store.refresh()
        }
        .sheet(isPresented: $isShowingNewBaseSheet) {
            NavigationStack {
                KnowledgeBaseEditorSheet(
                    embeddingModels: viewModel.embeddingModelOptions,
                    selectedEmbeddingModel: viewModel.selectedEmbeddingModel
                )
            }
        }
        .alert(NSLocalizedString("知识库操作失败", comment: "知识库错误弹窗标题"), isPresented: errorPresented) {
            Button(NSLocalizedString("好", comment: "确认按钮"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var settingsIntroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("知识库", comment: "知识库介绍标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString("把文档、网页和笔记整理成可检索资料，为后续 RAG 引用做准备。", comment: "知识库介绍摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
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

private struct KnowledgeBaseRow: View {
    let base: KnowledgeBase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(base.name)
                .etFont(.body)
            if !base.description.isEmpty {
                Text(base.description)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(summary)
                .etFont(.caption)
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
        Form {
            Section {
                TextField(NSLocalizedString("名称", comment: "知识库名称输入框"), text: $name)
                TextField(NSLocalizedString("描述", comment: "知识库描述输入框"), text: $description, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text(NSLocalizedString("基础信息", comment: "知识库基础信息分组"))
            }

            Section {
                Picker(NSLocalizedString("嵌入模型", comment: "知识库嵌入模型选择"), selection: $selectedEmbeddingModelID) {
                    Text(NSLocalizedString("未选择", comment: "未选择选项")).tag("")
                    ForEach(embeddingModels) { runnable in
                        Text(runnable.model.displayName).tag(runnable.id)
                    }
                }
            } footer: {
                Text(NSLocalizedString("首版会保存模型选择和分块参数；真正的嵌入生成会在后续索引队列接入。", comment: "知识库嵌入模型说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("新建知识库", comment: "新建知识库标题"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "取消按钮")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("创建", comment: "创建按钮")) {
                    Task { await create() }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    @State private var isShowingFileImporter = false
    @State private var isImportingFile = false
    @State private var errorMessage: String?

    private var base: KnowledgeBase? {
        store.knowledgeBases.first { $0.id == baseID }
    }

    var body: some View {
        List {
            if let base {
                Section {
                    LabeledContent(
                        NSLocalizedString("嵌入模型", comment: "知识库嵌入模型标签"),
                        value: base.settings.embeddingModelDisplayName ?? NSLocalizedString("未选择", comment: "未选择值")
                    )
                    LabeledContent(
                        NSLocalizedString("分块参数", comment: "知识库分块参数标签"),
                        value: chunkSettingsText(for: base)
                    )
                    LabeledContent(
                        NSLocalizedString("检索参数", comment: "知识库检索参数标签"),
                        value: retrievalSettingsText(for: base)
                    )
                } header: {
                    Text(NSLocalizedString("设置", comment: "知识库设置分组"))
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

                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label(NSLocalizedString("导入文件", comment: "导入知识库文件按钮"), systemImage: "doc")
                    }
                    .disabled(isImportingFile)
                } header: {
                    Text(NSLocalizedString("添加资料", comment: "知识库添加资料分组"))
                } footer: {
                    Text(NSLocalizedString("本地文件会在后台抽取文本；URL 会下载正文并保存为资料项。", comment: "知识库添加资料说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if base.items.isEmpty {
                        Text(NSLocalizedString("还没有资料。", comment: "知识库资料空状态"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(base.items) { item in
                            KnowledgeBaseItemRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await delete(item) }
                                    } label: {
                                        Label(NSLocalizedString("删除", comment: "删除按钮"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text(NSLocalizedString("资料", comment: "知识库资料分组"))
                }
            }
        }
        .navigationTitle(base?.name ?? NSLocalizedString("知识库", comment: "知识库页标题"))
        .task {
            store.refresh()
        }
        .sheet(isPresented: $isShowingNoteSheet) {
            NavigationStack {
                KnowledgeBaseNoteSheet(baseID: baseID)
            }
        }
        .sheet(isPresented: $isShowingURLSheet) {
            NavigationStack {
                KnowledgeBaseURLSheet(baseID: baseID)
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
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

    private func delete(_ item: KnowledgeBaseSourceItem) async {
        do {
            try await store.deleteItem(baseID: baseID, itemID: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chunkSettingsText(for base: KnowledgeBase) -> String {
        String(
            format: NSLocalizedString("%d 字 / 重叠 %d", comment: "知识库分块参数值"),
            base.settings.chunkSize,
            base.settings.chunkOverlap
        )
    }

    private func retrievalSettingsText(for base: KnowledgeBase) -> String {
        String(
            format: NSLocalizedString("Top %d / 阈值 %.2f", comment: "知识库检索参数值"),
            base.settings.retrievalDocumentCount,
            base.settings.scoreThreshold
        )
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isImportingFile = true
            for url in urls {
                let imported = try await KnowledgeBaseLocalFileImporter.importText(from: url)
                try await store.addFileText(
                    to: baseID,
                    fileName: imported.fileName,
                    mimeType: imported.mimeType,
                    byteCount: imported.byteCount,
                    content: imported.text
                )
            }
            isImportingFile = false
        } catch {
            isImportingFile = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct KnowledgeBaseItemRow: View {
    let item: KnowledgeBaseSourceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .etFont(.body)
                Spacer()
                Text(item.kind.localizedTitle)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.contentPreview.isEmpty {
                Text(item.contentPreview)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(summary)
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let status = item.status.localizedTitle
        let chunkCount = String(format: NSLocalizedString("%d 个分块", comment: "知识库分块数量"), item.chunkCount)
        let charCount = String(format: NSLocalizedString("%d 字", comment: "知识库字符数量"), item.contentCharacterCount)
        return "\(status) · \(chunkCount) · \(charCount)"
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
        Form {
            Section {
                TextField(NSLocalizedString("标题", comment: "知识库笔记标题输入框"), text: $title)
                TextField(NSLocalizedString("内容", comment: "知识库笔记内容输入框"), text: $content, axis: .vertical)
                    .lineLimit(5...12)
            }
        }
        .navigationTitle(NSLocalizedString("添加笔记", comment: "添加知识库笔记标题"))
        .navigationBarTitleDisplayMode(.inline)
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
        Form {
            Section {
                TextField(NSLocalizedString("URL", comment: "知识库 URL 输入框"), text: $urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField(NSLocalizedString("标题（可选）", comment: "知识库 URL 标题输入框"), text: $title)
            } footer: {
                Text(NSLocalizedString("会下载页面正文，适合 watchOS 无法选择文件时补充资料。", comment: "知识库 URL 导入说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("从 URL 下载", comment: "知识库 URL 导入标题"))
        .navigationBarTitleDisplayMode(.inline)
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

private struct KnowledgeBaseImportedFileText {
    var fileName: String
    var mimeType: String
    var byteCount: Int
    var text: String
}

private enum KnowledgeBaseLocalFileImporter {
    static func importText(from url: URL) async throws -> KnowledgeBaseImportedFileText {
        try await Task.detached(priority: .userInitiated) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let mimeType = resolvedFileMimeType(for: url)
            let attachment = FileAttachment(
                data: data,
                mimeType: mimeType,
                fileName: url.lastPathComponent
            )
            let text = try FileAttachmentTextExtractor().extractText(from: attachment)
            return KnowledgeBaseImportedFileText(
                fileName: url.lastPathComponent,
                mimeType: mimeType,
                byteCount: data.count,
                text: text
            )
        }.value
    }
}
