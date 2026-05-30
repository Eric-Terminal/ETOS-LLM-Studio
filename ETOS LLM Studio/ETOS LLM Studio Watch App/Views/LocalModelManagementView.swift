// ============================================================================
// LocalModelManagementView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 管理手表端本机 GGUF 权重入口。
// ============================================================================

import SwiftUI
import Shared

struct LocalModelManagementView: View {
    @ObservedObject private var store = LocalModelStore.shared
    @State private var downloadURLText = ""
    @State private var displayName = ""
    @State private var isDownloading = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("模型文件链接", comment: "Local model download URL"), text: $downloadURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                TextField(NSLocalizedString("名称", comment: "Local model display name"), text: $displayName.watchKeyboardNewlineBinding())
                Button {
                    downloadModel()
                } label: {
                    if isDownloading {
                        ProgressView()
                    } else {
                        Label(NSLocalizedString("下载权重", comment: "Download local model"), systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isDownloading || normalizedURL == nil)
            } footer: {
                Text(NSLocalizedString("下载后的模型只保存在当前手表。", comment: "Watch local model download footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if store.models.isEmpty {
                    Text(NSLocalizedString("还没有本地模型。", comment: "No local models"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.models) { record in
                        NavigationLink {
                            LocalModelDetailView(record: record)
                        } label: {
                            LocalModelRow(record: record, fileExists: store.fileExists(for: record))
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("权重", comment: "Local model weights section"))
            }
        }
        .navigationTitle(NSLocalizedString("本地模型", comment: "Local models title"))
    }

    private var normalizedURL: URL? {
        let text = downloadURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private func downloadModel() {
        guard let url = normalizedURL else { return }
        isDownloading = true
        statusMessage = nil
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let suggestedName = url.lastPathComponent.isEmpty ? "model.gguf" : url.lastPathComponent
                _ = try store.registerDownloadedModel(
                    data: data,
                    suggestedFileName: suggestedName,
                    displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : displayName
                )
                await MainActor.run {
                    downloadURLText = ""
                    displayName = ""
                    statusMessage = NSLocalizedString("下载完成。", comment: "Local model download completed")
                    isDownloading = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isDownloading = false
                }
            }
        }
    }
}

private struct LocalModelRow: View {
    let record: LocalModelRecord
    let fileExists: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: fileExists ? "cpu" : "exclamationmark.triangle")
                    .foregroundStyle(fileExists ? .blue : .orange)
                Text(record.sanitizedDisplayName)
                    .lineLimit(1)
                Spacer()
            }
            Text(StorageUtility.formatSize(record.fileSize))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            if !record.isActivated {
                Text(NSLocalizedString("未启用", comment: "Inactive local model"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } else if !fileExists {
                Text(NSLocalizedString("文件缺失", comment: "Missing local model file"))
                    .etFont(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct LocalModelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LocalModelStore.shared
    @State private var draft: LocalModelRecord

    init(record: LocalModelRecord) {
        _draft = State(initialValue: record)
    }

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("名称", comment: "Local model display name"), text: $draft.displayName.watchKeyboardNewlineBinding())
                Toggle(NSLocalizedString("加入候选模型", comment: "Activate local model"), isOn: $draft.isActivated)
            }

            Section {
                Stepper(value: $draft.contextSize, in: 1...262_144, step: 256) {
                    Text("\(NSLocalizedString("上下文", comment: "Local model context size")) \(draft.contextSize)")
                }
                Stepper(value: $draft.maxOutputTokens, in: 1...65_536, step: 128) {
                    Text("\(NSLocalizedString("输出", comment: "Local model output tokens")) \(draft.maxOutputTokens)")
                }
            }

            Section {
                Text(draft.fileName)
                    .etFont(.caption2)
                    .lineLimit(2)
                Text(StorageUtility.formatSize(draft.fileSize))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.fileExists(for: draft)
                    ? NSLocalizedString("文件可用", comment: "Local model file exists")
                    : NSLocalizedString("文件缺失", comment: "Local model file missing"))
                    .etFont(.caption2)
                    .foregroundStyle(store.fileExists(for: draft) ? Color.secondary : Color.orange)
            }

            Section {
                Button {
                    store.update(draft)
                    dismiss()
                } label: {
                    Label(NSLocalizedString("保存", comment: "Save"), systemImage: "checkmark")
                }

                Button(role: .destructive) {
                    store.delete(draft)
                    dismiss()
                } label: {
                    Label(NSLocalizedString("删除权重", comment: "Delete local model"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(draft.sanitizedDisplayName)
    }
}
