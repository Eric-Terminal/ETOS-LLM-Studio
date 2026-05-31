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
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var downloadURLText = ""
    @State private var displayName = ""
    @State private var isDownloading = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("启用本地模型提供商", comment: "Enable local model provider"), isOn: localModelsEnabledBinding)
            } footer: {
                Text(NSLocalizedString("关闭后不会删除权重；重新开启时会自动恢复到模型管理。", comment: "Watch local provider toggle footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

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

    private var localModelsEnabledBinding: Binding<Bool> {
        Binding {
            appConfig.localModelsEnabled
        } set: { isEnabled in
            appConfig.localModelsEnabled = isEnabled
            ChatService.shared.setLocalModelsEnabled(isEnabled)
        }
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
    @State private var contextSizeText: String
    @State private var maxOutputTokensText: String
    @State private var gpuLayersText: String
    @State private var advancedArgumentsText: String

    init(record: LocalModelRecord) {
        _draft = State(initialValue: record)
        _contextSizeText = State(initialValue: "\(record.contextSize)")
        _maxOutputTokensText = State(initialValue: "\(record.maxOutputTokens)")
        _gpuLayersText = State(initialValue: "\(record.gpuLayers)")
        _advancedArgumentsText = State(initialValue: record.advancedArguments)
    }

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("名称", comment: "Local model display name"), text: $draft.displayName.watchKeyboardNewlineBinding())
                Toggle(NSLocalizedString("加入候选模型", comment: "Activate local model"), isOn: $draft.isActivated)
            }

            Section {
                LocalModelIntegerField(
                    title: NSLocalizedString("上下文", comment: "Local model context size"),
                    text: $contextSizeText
                )
                LocalModelIntegerField(
                    title: NSLocalizedString("输出上限", comment: "Local model max output tokens"),
                    text: $maxOutputTokensText
                )
                LocalModelIntegerField(
                    title: NSLocalizedString("GPU 层数", comment: "Local model GPU layers"),
                    text: $gpuLayersText
                )
            } footer: {
                Text(NSLocalizedString("watchOS 推理会自动走 CPU；参数只按填写值保存。", comment: "Watch local model parameter footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(NSLocalizedString("例如 --temp 0.7 --top-p 0.9", comment: "Watch local llama CLI arguments placeholder"), text: $advancedArgumentsText.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
            } header: {
                Text(NSLocalizedString("llama.cpp CLI 参数", comment: "Local llama CLI arguments section"))
            } footer: {
                Text(NSLocalizedString("这些参数会直接影响采样链和上下文；乱写可能导致请求失败、内存暴涨或软件崩溃。", comment: "Watch local llama CLI arguments warning footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
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
                    applyDraftNumbers()
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

    private func applyDraftNumbers() {
        if let contextSize = Int(contextSizeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.contextSize = max(1, contextSize)
        }
        if let maxOutputTokens = Int(maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.maxOutputTokens = max(1, maxOutputTokens)
        }
        if let gpuLayers = Int(gpuLayersText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.gpuLayers = gpuLayers
        }
        draft.advancedArguments = advancedArgumentsText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct LocalModelIntegerField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            TextField(title, text: $text.watchKeyboardNewlineBinding())
        }
    }
}
