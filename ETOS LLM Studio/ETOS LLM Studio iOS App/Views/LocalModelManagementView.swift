// ============================================================================
// LocalModelManagementView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 管理本机 GGUF 权重入口。
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import Shared

struct LocalModelManagementView: View {
    @ObservedObject private var store = LocalModelStore.shared
    @State private var isImportingModel = false
    @State private var errorMessage: String?

    private let ggufType = UTType(filenameExtension: "gguf") ?? .data

    var body: some View {
        List {
            Section {
                Button {
                    isImportingModel = true
                } label: {
                    Label(NSLocalizedString("导入 GGUF 权重", comment: "Import local GGUF model"), systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text(NSLocalizedString("导入后的权重只保存在本机，并会以“本地模型”出现在模型候选列表中。", comment: "Local model import footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.models.isEmpty {
                    Text(NSLocalizedString("还没有本地模型。", comment: "No local models"))
                        .etFont(.footnote)
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
        .fileImporter(
            isPresented: $isImportingModel,
            allowedContentTypes: [ggufType, .data],
            allowsMultipleSelection: false
        ) { result in
            importModel(result)
        }
        .alert(NSLocalizedString("本地模型", comment: "Local models alert title"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: "OK"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importModel(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            _ = try store.importModel(from: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LocalModelRow: View {
    let record: LocalModelRecord
    let fileExists: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileExists ? "cpu" : "exclamationmark.triangle")
                .etFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(fileExists ? .blue : .orange)
                .frame(width: 32, height: 32)
                .background((fileExists ? Color.blue : Color.orange).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.sanitizedDisplayName)
                    .etFont(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(record.fileName) · \(StorageUtility.formatSize(record.fileSize))")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !record.isActivated {
                Text(NSLocalizedString("未启用", comment: "Inactive local model"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } else if !fileExists {
                Text(NSLocalizedString("缺文件", comment: "Missing local model file"))
                    .etFont(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LocalModelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LocalModelStore.shared
    @State private var draft: LocalModelRecord
    @State private var showDeleteAlert = false

    init(record: LocalModelRecord) {
        _draft = State(initialValue: record)
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("名称", comment: "Local model display name field"), text: $draft.displayName)
                Toggle(NSLocalizedString("加入候选模型", comment: "Activate local model"), isOn: $draft.isActivated)
            }

            Section {
                Stepper(value: $draft.contextSize, in: 1...262_144, step: 256) {
                    HStack {
                        Text(NSLocalizedString("上下文", comment: "Local model context size"))
                        Spacer()
                        Text("\(draft.contextSize)")
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: $draft.maxOutputTokens, in: 1...65_536, step: 128) {
                    HStack {
                        Text(NSLocalizedString("输出上限", comment: "Local model max output tokens"))
                        Spacer()
                        Text("\(draft.maxOutputTokens)")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(NSLocalizedString("上下文和输出上限不做额外限制，过大的设置可能触发系统内存回收。", comment: "Local model parameter footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(NSLocalizedString("文件", comment: "Local model file label"), value: draft.fileName)
                LabeledContent(NSLocalizedString("大小", comment: "Local model size label"), value: StorageUtility.formatSize(draft.fileSize))
                LabeledContent(NSLocalizedString("状态", comment: "Local model file status")) {
                    Text(store.fileExists(for: draft)
                        ? NSLocalizedString("文件可用", comment: "Local model file exists")
                        : NSLocalizedString("文件缺失", comment: "Local model file missing"))
                        .foregroundStyle(store.fileExists(for: draft) ? Color.secondary : Color.orange)
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label(NSLocalizedString("删除权重", comment: "Delete local model"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(draft.sanitizedDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "Save")) {
                    store.update(draft)
                    dismiss()
                }
            }
        }
        .alert(NSLocalizedString("删除本地模型", comment: "Delete local model alert"), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                store.delete(draft)
                dismiss()
            }
        } message: {
            Text(NSLocalizedString("会同时删除本机保存的权重文件。", comment: "Delete local model alert message"))
        }
    }
}
