// ============================================================================
// MemoryTransferView.swift
// ETOS LLM Studio
// ============================================================================

import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let etosMemoryArchive = UTType(
        importedAs: "com.ericterminal.els.memory-archive",
        conformingTo: .zip
    )
}

struct MemoryTransferView: View {
    @State private var isBusy = false
    @State private var isChoosingArchive = false
    @State private var generatedURL: URL?
    @State private var importPreview: MemoryImportPreview?
    @State private var receipts: [MemoryTransferReceipt] = []
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private let service = MemoryTransferService()

    var body: some View {
        Form {
            Section {
                Button {
                    exportMarkdown()
                } label: {
                    Label(NSLocalizedString("导出 Markdown 目录", comment: "Export memories as Markdown action"), systemImage: "doc.text")
                }
                Button {
                    exportArchive()
                } label: {
                    Label(NSLocalizedString("导出可恢复归档", comment: "Export recoverable memory archive action"), systemImage: "archivebox")
                }
                if let generatedURL {
                    ShareLink(item: generatedURL) {
                        Label(NSLocalizedString("分享最近导出", comment: "Share latest memory export action"), systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text(NSLocalizedString("导出", comment: "Memory export section title"))
            } footer: {
                Text(NSLocalizedString("Markdown 目录适合阅读；.etosmemory 归档保留稳定 ID 与完整元数据，可在另一台设备预览后恢复。", comment: "Memory export footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    isChoosingArchive = true
                } label: {
                    Label(NSLocalizedString("选择 .etosmemory 归档", comment: "Choose memory archive action"), systemImage: "square.and.arrow.down")
                }
            } header: {
                Text(NSLocalizedString("导入", comment: "Memory import section title"))
            } footer: {
                Text(NSLocalizedString("导入会先检查路径、大小、重复 ID 和文件完整性；冲突会保留本机版本，不会静默覆盖。", comment: "Memory import footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isBusy || statusMessage != nil || errorMessage != nil {
                Section(NSLocalizedString("状态", comment: "Memory transfer status section")) {
                    if isBusy {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("正在处理记忆文件…", comment: "Memory transfer progress"))
                        }
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section(NSLocalizedString("最近记录", comment: "Memory transfer receipts section")) {
                if receipts.isEmpty {
                    Text(NSLocalizedString("还没有记忆导入导出记录。", comment: "No memory transfer receipts"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading) {
                            Text(receiptTitle(receipt))
                            Text(receipt.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(receiptSummary(receipt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .disabled(isBusy)
        .navigationTitle(NSLocalizedString("记忆导入与导出", comment: "Memory transfer page title"))
        .fileImporter(
            isPresented: $isChoosingArchive,
            allowedContentTypes: [.etosMemoryArchive, .zip],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
                return
            }
            previewArchive(at: url)
        }
        .sheet(item: $importPreview) { preview in
            NavigationStack {
                MemoryImportPreviewView(preview: preview) {
                    applyImport(preview)
                }
            }
        }
        .task { await reloadReceipts() }
    }

    private func exportMarkdown() {
        runOperation {
            generatedURL = try await service.exportMarkdownDirectory()
            statusMessage = NSLocalizedString("Markdown 目录已生成，可从最近导出分享。", comment: "Memory Markdown export completed")
        }
    }

    private func exportArchive() {
        runOperation {
            generatedURL = try await service.exportArchive()
            statusMessage = NSLocalizedString("可恢复记忆归档已生成。", comment: "Memory archive export completed")
        }
    }

    private func previewArchive(at url: URL) {
        runOperation {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            importPreview = try await service.previewImport(from: url)
        }
    }

    private func applyImport(_ preview: MemoryImportPreview) {
        importPreview = nil
        runOperation {
            let granted = preview.sourceURL.startAccessingSecurityScopedResource()
            defer { if granted { preview.sourceURL.stopAccessingSecurityScopedResource() } }
            let result = try await service.applyImport(preview)
            statusMessage = String(
                format: NSLocalizedString("导入完成：恢复 %d 条，保留 %d 个冲突。", comment: "Memory import completed summary"),
                result.importedCount,
                result.receipt.conflictCount
            )
        }
    }

    private func runOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await operation()
                await reloadReceipts()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func reloadReceipts() async {
        receipts = await MemoryManager.shared.transferReceipts(limit: 20)
    }

    private func receiptTitle(_ receipt: MemoryTransferReceipt) -> String {
        switch receipt.kind {
        case .markdownExport: return NSLocalizedString("Markdown 导出", comment: "Markdown export receipt title")
        case .archiveExport: return NSLocalizedString("归档导出", comment: "Archive export receipt title")
        case .archiveImport: return NSLocalizedString("归档导入", comment: "Archive import receipt title")
        }
    }

    private func receiptSummary(_ receipt: MemoryTransferReceipt) -> String {
        String(
            format: NSLocalizedString("新增 %d · 更新 %d · 冲突 %d · 归档 %d", comment: "Memory transfer receipt counts"),
            receipt.addedCount,
            receipt.updatedCount,
            receipt.conflictCount,
            receipt.archivedCount
        )
    }
}

private struct MemoryImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: MemoryImportPreview
    let apply: () -> Void

    var body: some View {
        Form {
            Section(NSLocalizedString("导入预览", comment: "Memory import preview section")) {
                LabeledContent(NSLocalizedString("新增", comment: "Memory import additions"), value: "\(preview.addedCount)")
                LabeledContent(NSLocalizedString("更新", comment: "Memory import updates"), value: "\(preview.updatedCount)")
                LabeledContent(NSLocalizedString("冲突", comment: "Memory import conflicts"), value: "\(preview.conflictCount)")
                LabeledContent(NSLocalizedString("其中归档", comment: "Memory import archived count"), value: "\(preview.archivedCount)")
            }
            if preview.conflictCount > 0 {
                Section {
                    Text(NSLocalizedString("冲突条目的本机版本较新或时间相同，将保持不变。", comment: "Memory import conflict policy"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("确认记忆导入", comment: "Confirm memory import title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("导入", comment: "Import"), action: apply)
                    .disabled(preview.addedCount + preview.updatedCount == 0)
            }
        }
    }
}
