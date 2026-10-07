import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacMemoryTransferView: View {
    @ObservedObject var model: MacMemoryModel
    @State private var isImporting = false
    @State private var preview: MacMemoryImportPreview?
    @State private var exportedURL: URL?
    @State private var status: String?
    @State private var error: String?
    @State private var receipts: [MacMemoryTransferReceipt] = []

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(
                    id: "memory-transfer", title: NSLocalizedString("记忆导入与导出", comment: ""),
                    details: NSLocalizedString("Markdown 目录适合阅读；.etosmemory 归档保留稳定 ID 与完整元数据，可在另一台设备预览后恢复。", comment: ""),
                    documentID: "settings-memory"
                )
                Button(NSLocalizedString("导出 Markdown 目录", comment: "")) { export(markdown: true) }
                Button(NSLocalizedString("导出可恢复归档", comment: "")) { export(markdown: false) }
                if let exportedURL {
                    Button(NSLocalizedString("在 Finder 中显示", comment: "")) {
                        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                    }
                    ShareLink(item: exportedURL) { Text(NSLocalizedString("分享最近导出", comment: "")) }
                }
            } header: { Text(NSLocalizedString("导出", comment: "")) }
            Section {
                Button(NSLocalizedString("选择 .etosmemory 归档", comment: "")) { isImporting = true }
            } footer: {
                Text(NSLocalizedString("导入会先检查路径、大小、重复 ID 和文件完整性；冲突会保留本机版本，不会静默覆盖。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.isWorking { ProgressView(NSLocalizedString("正在处理记忆文件…", comment: "")) }
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Section(NSLocalizedString("最近记录", comment: "")) {
                ForEach(receipts) { receipt in
                    VStack(alignment: .leading) {
                        Text(receipt.title)
                        Text(receipt.date).font(.caption).foregroundStyle(.secondary)
                        Text(receipt.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isWorking || !model.isLoaded)
        .navigationTitle(NSLocalizedString("记忆导入与导出", comment: ""))
        .task { await reloadReceipts() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                error = nil
                status = nil
                Task {
                    do {
                        preview = try await model.performTransfer { service in
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            return MacMemoryImportPreview(try await service.previewImport(from: url))
                        }
                    } catch { self.error = error.localizedDescription }
                }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .sheet(item: $preview) { preview in
            MacMemoryImportConfirmation(preview: preview) { apply(preview) }
        }
        .guideSettingsPageContext(
            id: "mac-memory-transfer", title: NSLocalizedString("记忆导入与导出", comment: ""),
            documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
            settings: [
                .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(model.isWorking) }),
                .readOnly("file_ready", label: NSLocalizedString("分享最近导出", comment: ""), value: { .bool(exportedURL != nil) }),
                .readOnly("requires_manual_action", label: NSLocalizedString("导入与导出", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private func export(markdown: Bool) {
        error = nil
        status = nil
        Task {
            do {
                exportedURL = try await model.performTransfer { service in
                    if markdown { return try await service.exportMarkdownDirectory() }
                    return try await service.exportArchive()
                }
                status = markdown ? NSLocalizedString("Markdown 目录已生成，可从最近导出分享。", comment: "") : NSLocalizedString("可恢复记忆归档已生成。", comment: "")
                await reloadReceipts()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func apply(_ preview: MacMemoryImportPreview) {
        self.preview = nil
        error = nil
        status = nil
        Task {
            do {
                let result = try await model.performTransfer { service in
                    let url = preview.source.sourceURL
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try await service.applyImport(preview.source)
                }
                status = String(format: NSLocalizedString("导入完成：恢复 %d 条，保留 %d 个冲突。", comment: ""), result.importedCount, result.receipt.conflictCount)
                await reloadReceipts()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func reloadReceipts() async {
        receipts = await Task.detached(priority: .utility) {
            let records = await MemoryManager.shared.transferReceipts(limit: 20)
            return records.map(MacMemoryTransferReceipt.init)
        }.value
    }
}

private struct MacMemoryTransferReceipt: Identifiable, Sendable {
    let id: UUID
    let title: String
    let date: String
    let summary: String

    init(_ receipt: MemoryTransferReceipt) {
        id = receipt.id
        switch receipt.kind {
        case .markdownExport: title = NSLocalizedString("Markdown 导出", comment: "")
        case .archiveExport: title = NSLocalizedString("归档导出", comment: "")
        case .archiveImport: title = NSLocalizedString("归档导入", comment: "")
        }
        date = receipt.createdAt.formatted(date: .abbreviated, time: .shortened)
        summary = String(format: NSLocalizedString("新增 %d · 更新 %d · 冲突 %d · 归档 %d", comment: ""), receipt.addedCount, receipt.updatedCount, receipt.conflictCount, receipt.archivedCount)
    }
}

private struct MacMemoryImportPreview: Identifiable, Sendable {
    let source: MemoryImportPreview
    let added: Int
    let updated: Int
    let conflicts: Int
    let archived: Int
    var id: String { source.id }

    init(_ source: MemoryImportPreview) {
        self.source = source
        added = source.addedCount
        updated = source.updatedCount
        conflicts = source.conflictCount
        archived = source.archivedCount
    }
}

private struct MacMemoryImportConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let preview: MacMemoryImportPreview
    let apply: () -> Void
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent(NSLocalizedString("新增", comment: ""), value: String(preview.added))
                LabeledContent(NSLocalizedString("更新", comment: ""), value: String(preview.updated))
                LabeledContent(NSLocalizedString("冲突", comment: ""), value: String(preview.conflicts))
                LabeledContent(NSLocalizedString("其中归档", comment: ""), value: String(preview.archived))
                Text(NSLocalizedString("冲突条目的本机版本较新或时间相同，将保持不变。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("确认记忆导入", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("导入", comment: "")) { isSubmitting = true; apply() }
                        .disabled(isSubmitting || preview.added + preview.updated == 0)
                }
            }
            .guideSettingsPageContext(
                id: "mac-memory-import-confirmation", title: NSLocalizedString("确认记忆导入", comment: ""),
                documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
                settings: [
                    .readOnly("added", label: NSLocalizedString("新增", comment: ""), value: { .int(preview.added) }),
                    .readOnly("updated", label: NSLocalizedString("更新", comment: ""), value: { .int(preview.updated) }),
                    .readOnly("conflicts", label: NSLocalizedString("冲突", comment: ""), value: { .int(preview.conflicts) }),
                    .readOnly("archived", label: NSLocalizedString("其中归档", comment: ""), value: { .int(preview.archived) }),
                    .readOnly("requires_manual_confirmation", label: NSLocalizedString("导入", comment: ""), value: { .bool(true) })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 480, minHeight: 340)
    }
}
