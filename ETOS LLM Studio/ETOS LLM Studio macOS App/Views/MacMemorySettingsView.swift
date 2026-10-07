import ETOSCore
import SwiftUI

struct MacMemorySettingsView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject var model: MacMemoryModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var editor: MacMemoryEditorItem?
    @State private var pendingDeletion: MemoryItem?

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(
                    id: "memory", title: NSLocalizedString("记忆检索", comment: ""),
                    details: NSLocalizedString("记忆检索说明正文", comment: ""), documentID: "settings-memory"
                )
                Picker(NSLocalizedString("嵌入模型", comment: ""), selection: $configuration.memoryEmbeddingModelIdentifier) {
                    Text(NSLocalizedString("未选择", comment: "")).tag("")
                    if !model.embeddingModelIDSet.contains(configuration.memoryEmbeddingModelIdentifier) {
                        Text(NSLocalizedString("已选模型不可用", comment: "")).tag(configuration.memoryEmbeddingModelIdentifier)
                    }
                    ForEach(model.embeddingModels) { model in Text(model.model.displayName).tag(model.id) }
                }
                Stepper(value: $configuration.memoryTopK, in: 0...Int.max) {
                    LabeledContent(NSLocalizedString("检索数量 (Top K)", comment: ""), value: String(configuration.memoryTopK))
                }
                Toggle(NSLocalizedString("发送更新时间", comment: ""), isOn: $configuration.memorySendUpdateTime)
                Toggle(NSLocalizedString("主动检索", comment: ""), isOn: $configuration.enableMemoryActiveRetrieval)
                Toggle(NSLocalizedString("低频自动整理", comment: ""), isOn: $configuration.enableMemoryAutoConsolidation)
            }
            .disabled(model.isWorking)
            Section {
                NavigationLink(NSLocalizedString("数据维护", comment: "")) { MacMemoryMaintenanceView(model: model) }
                NavigationLink(NSLocalizedString("导入与导出", comment: "")) { MacMemoryTransferView(model: model) }
                Button(NSLocalizedString("添加记忆", comment: "")) { editor = MacMemoryEditorItem(row: nil) }
                    .disabled(!model.isLoaded || model.isWorking)
            }
            Section {
                TextField(NSLocalizedString("搜索记忆", comment: ""), text: $model.query)
                Toggle(NSLocalizedString("已归档", comment: ""), isOn: $model.showsArchived)
                if !model.isLoaded { ProgressView() }
                ForEach(model.rows) { row in
                    Button { editor = MacMemoryEditorItem(row: row) } label: {
                        VStack(alignment: .leading) {
                            Text(row.preview).lineLimit(2)
                            Text(row.date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) { pendingDeletion = row.item }
                    }
                }
            } header: { Text(NSLocalizedString("记忆", comment: "")) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("记忆", comment: ""))
        .task { await model.start(service: workspace.service) }
        .sheet(item: $editor) { item in MacMemoryEditor(model: model, row: item.row) }
        .confirmationDialog(NSLocalizedString("删除记忆", comment: ""), isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let item = pendingDeletion { Task { await model.delete(item) } }
                pendingDeletion = nil
            }
        }
        .alert(NSLocalizedString("操作失败", comment: ""), isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .guideSettingsPageContext(
            id: "mac-memory", title: NSLocalizedString("记忆", comment: ""),
            documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
            settings: model.isWorking ? [.readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })] : [
                .string("embedding_model", label: NSLocalizedString("嵌入模型", comment: ""), allowedValues: model.embeddingModelIDs, get: { configuration.memoryEmbeddingModelIdentifier }, set: { configuration.memoryEmbeddingModelIdentifier = $0 }),
                .integer("top_k", label: NSLocalizedString("检索数量 (Top K)", comment: ""), range: 0...Int.max, get: { configuration.memoryTopK }, set: { configuration.memoryTopK = $0 }),
                .bool("send_time", label: NSLocalizedString("发送更新时间", comment: ""), get: { configuration.memorySendUpdateTime }, set: { configuration.memorySendUpdateTime = $0 }),
                .bool("active_retrieval", label: NSLocalizedString("主动检索", comment: ""), get: { configuration.enableMemoryActiveRetrieval }, set: { configuration.enableMemoryActiveRetrieval = $0 }),
                .bool("consolidation", label: NSLocalizedString("低频自动整理", comment: ""), get: { configuration.enableMemoryAutoConsolidation }, set: { configuration.enableMemoryAutoConsolidation = $0 }),
                .readOnly("count", label: NSLocalizedString("记忆", comment: ""), value: { .int(model.rows.count) })
            ]
        )
    }
}

private struct MacMemoryEditorItem: Identifiable {
    let id = UUID()
    let row: MacMemoryRow?
}

private struct MacMemoryMaintenanceView: View {
    @ObservedObject var model: MacMemoryModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var confirmsReembed = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $configuration.memoryReembeddingConcurrencyLimit, in: 1...Int.max) {
                    LabeledContent(NSLocalizedString("并发数量", comment: ""), value: String(configuration.memoryReembeddingConcurrencyLimit))
                }
                Button(NSLocalizedString("重新生成全部嵌入", comment: ""), role: .destructive) { confirmsReembed = true }
            } footer: {
                Text(NSLocalizedString("会清理旧的向量数据库，并按当前记忆重新生成嵌入。并发数量会自动保存。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(model.isWorking)
            if let progress = model.progress {
                ProgressView(value: Double(progress.processedMemories), total: Double(max(1, progress.totalMemories)))
                if let text = progress.currentMemoryPreview { Text(text).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(model.reembeddingResults) { result in
                Section {
                    Label(model.memoryTitles[result.memoryID] ?? NSLocalizedString("记忆", comment: ""), systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    if let error = result.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button(NSLocalizedString("重试", comment: "")) { Task { await model.retryEmbedding(id: result.memoryID) } }
                            .disabled(model.isWorking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("数据维护", comment: ""))
        .confirmationDialog(NSLocalizedString("重新生成全部嵌入", comment: ""), isPresented: $confirmsReembed) {
            Button(NSLocalizedString("确定", comment: ""), role: .destructive) { Task { await model.reembed() } }
        }
        .guideSettingsPageContext(
            id: "mac-memory-maintenance", title: NSLocalizedString("数据维护", comment: ""),
            documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
            settings: model.isWorking ? [.readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })] : [
                .integer("concurrency", label: NSLocalizedString("并发数量", comment: ""), range: 1...Int.max, get: { configuration.memoryReembeddingConcurrencyLimit }, set: { configuration.memoryReembeddingConcurrencyLimit = $0 }),
                .readOnly("requires_manual_action", label: NSLocalizedString("重新生成全部嵌入", comment: ""), value: { .bool(true) })
            ]
        )
    }
}
