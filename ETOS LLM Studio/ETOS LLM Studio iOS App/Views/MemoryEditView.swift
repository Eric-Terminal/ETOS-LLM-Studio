// ============================================================================
// MemoryEditView.swift
// ============================================================================
// MemoryEditView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct MemoryEditView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var memory: MemoryItem
    @State private var hasChanges = false
    @State private var isReembeddingMemory = false
    @State private var reembedStatusMessage: String?
    @State private var reembedStatusIsError = false
    @State private var reembedAlert: MemoryReembedAlert?
    @State private var showUnsavedChangesAlert = false
    
    init(memory: MemoryItem) {
        _memory = State(initialValue: memory)
    }
    
    var body: some View {
        Form {
            Section(NSLocalizedString("记忆内容", comment: "")) {
                TextEditor(text: $memory.content)
                    .frame(minHeight: 180)
                    .onChange(of: memory.content) { _, _ in
                        hasChanges = true
                    }
            }
            
            Section {
                Toggle(isOn: $memory.isArchived) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memory.isArchived ? NSLocalizedString("已归档", comment: "") : NSLocalizedString("激活中", comment: ""))
                        Text(memory.isArchived ? NSLocalizedString("不参与检索", comment: "") : NSLocalizedString("参与检索", comment: ""))
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: memory.isArchived) { _, _ in
                    hasChanges = true
                }
            } header: {
                Text(NSLocalizedString("状态", comment: ""))
            }
            
            Section {
                LabeledContent(NSLocalizedString("更新时间", comment: "")) {
                    Text(memory.displayDate.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    triggerMemoryReembed()
                } label: {
                    if isReembeddingMemory {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("重新嵌入中…", comment: "Single memory reembedding in progress"))
                        }
                    } else {
                        Label(reembedButtonTitle, systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isReembeddingMemory || memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let reembedStatusMessage {
                    Text(reembedStatusMessage)
                        .etFont(.caption)
                        .foregroundStyle(reembedStatusIsError ? .orange : .secondary)
                }
            } header: {
                Text(NSLocalizedString("嵌入", comment: "Memory embedding section"))
            } footer: {
                Text(NSLocalizedString("如果当前页面有未保存更改，会先保存再重新嵌入。", comment: "Single memory reembedding footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("编辑记忆", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .alert(item: $reembedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("好的", comment: "")))
            )
        }
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        requestDismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel(NSLocalizedString("返回", comment: "Back button"))
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(NSLocalizedString("保存", comment: "")) {
                    saveMemory()
                }
                .disabled(!canSaveChanges)
            }
        }
        .alert(NSLocalizedString("未保存更改", comment: "Unsaved changes alert title"), isPresented: $showUnsavedChangesAlert) {
            if canSaveChanges {
                Button(NSLocalizedString("保存并离开", comment: "Save changes and leave")) {
                    saveMemory()
                }
            }
            Button(NSLocalizedString("放弃更改", comment: "Discard changes"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("继续编辑", comment: "Continue editing"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("要保存当前编辑内容，还是放弃更改并离开？", comment: "Unsaved generic editor alert message"))
        }
    }

    private var reembedButtonTitle: String {
        hasChanges
            ? NSLocalizedString("保存并重新嵌入", comment: "Save and reembed single memory")
            : NSLocalizedString("重新嵌入这条记忆", comment: "Reembed single memory")
    }

    private var canSaveChanges: Bool {
        hasChanges && !isReembeddingMemory && !memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestDismiss() {
        if hasChanges {
            showUnsavedChangesAlert = true
        } else {
            dismiss()
        }
    }

    private func saveMemory() {
        guard canSaveChanges else { return }
        Task {
            await viewModel.updateMemory(item: memory)
            dismiss()
        }
    }

    private func triggerMemoryReembed() {
        guard !isReembeddingMemory else { return }
        let shouldSaveBeforeReembed = hasChanges
        let draftMemory = memory
        isReembeddingMemory = true
        reembedStatusMessage = nil
        reembedStatusIsError = false

        Task {
            if shouldSaveBeforeReembed {
                await viewModel.updateMemory(item: draftMemory)
            }

            do {
                let results = try await viewModel.reembedMemories(withIDs: [draftMemory.id], concurrencyLimit: 1)
                await MainActor.run {
                    if shouldSaveBeforeReembed {
                        memory.updatedAt = Date()
                        hasChanges = false
                    }
                    finishReembed(with: results.first)
                }
            } catch {
                await MainActor.run {
                    if shouldSaveBeforeReembed {
                        memory.updatedAt = Date()
                        hasChanges = false
                    }
                    finishReembedFailure(message: error.localizedDescription)
                }
            }
        }
    }

    private func finishReembed(with result: MemoryReembeddingItemResult?) {
        isReembeddingMemory = false
        guard let result else {
            finishReembedFailure(message: NSLocalizedString("未找到这条记忆，无法重新嵌入。", comment: "Single memory reembedding missing result"))
            return
        }

        if result.succeeded {
            reembedStatusMessage = NSLocalizedString("最近一次重新嵌入成功。", comment: "Single memory reembedding success status")
            reembedStatusIsError = false
            reembedAlert = .success(
                summary: MemoryReembeddingSummary(
                    processedMemories: 1,
                    chunkCount: result.chunkCount
                )
            )
        } else {
            finishReembedFailure(message: result.errorMessage ?? NSLocalizedString("未知错误", comment: ""))
        }
    }

    private func finishReembedFailure(message: String) {
        isReembeddingMemory = false
        reembedStatusMessage = message
        reembedStatusIsError = true
        reembedAlert = .failure(message: message)
    }
}
