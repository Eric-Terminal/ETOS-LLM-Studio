// ============================================================================
// MemoryTransferView.swift
// ETOS LLM Studio
// ============================================================================

import ETOSCore
import SwiftUI

struct MemoryTransferView: View {
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var receipts: [MemoryTransferReceipt] = []

    private let service = MemoryTransferService()

    var body: some View {
        List {
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
            } header: {
                Text(NSLocalizedString("导出", comment: "Memory export section title"))
            } footer: {
                Text(NSLocalizedString("导出会保存到共享 Exports。归档导入请在配对的 iPhone 上完成。", comment: "Watch memory transfer footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isBusy {
                ProgressView(NSLocalizedString("正在处理记忆文件…", comment: "Memory transfer progress"))
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("最近记录", comment: "Memory transfer receipts section")) {
                if receipts.isEmpty {
                    Text(NSLocalizedString("还没有记忆导入导出记录。", comment: "No memory transfer receipts"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(receipts.prefix(10)) { receipt in
                        VStack(alignment: .leading) {
                            Text(receipt.fileName)
                                .lineLimit(1)
                            Text(receipt.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .disabled(isBusy)
        .navigationTitle(NSLocalizedString("记忆导入与导出", comment: "Memory transfer page title"))
        .task { await reloadReceipts() }
    }

    private func exportMarkdown() {
        runOperation { _ = try await service.exportMarkdownDirectory() }
    }

    private func exportArchive() {
        runOperation { _ = try await service.exportArchive() }
    }

    private func runOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            do {
                try await operation()
                statusMessage = NSLocalizedString("导出已保存到共享 Exports。", comment: "Watch memory export completed")
                await reloadReceipts()
            } catch {
                statusMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func reloadReceipts() async {
        receipts = await MemoryManager.shared.transferReceipts(limit: 10)
    }
}
