// ============================================================================
// MemoryEditView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了记忆编辑视图。
// 用户可以在此修改单条记忆的具体内容。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

public struct MemoryEditView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var memory: MemoryItem
    @State private var hasChanges = false
    @State private var isReembeddingMemory = false
    @State private var reembedStatusMessage: String?
    @State private var reembedStatusIsError = false
    @State private var reembedAlert: MemoryReembedAlert?
    @State private var showUnsavedChangesAlert = false
    
    public init(memory: MemoryItem) {
        _memory = State(initialValue: memory)
    }
    
    public var body: some View {
        Form {
            Section(header: Text(NSLocalizedString("记忆内容", comment: ""))) {
                TextField(NSLocalizedString("在此输入多行记忆内容...", comment: ""), text: $memory.content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(5...20)
                    .onChange(of: memory.content) { _, _ in
                        hasChanges = true
                    }
            }
            
            Section(header: Text(NSLocalizedString("状态", comment: ""))) {
                Toggle(isOn: $memory.isArchived) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memory.isArchived ? NSLocalizedString("已归档", comment: "") : NSLocalizedString("激活中", comment: ""))
                            .etFont(.footnote)
                        Text(memory.isArchived ? NSLocalizedString("不参与检索", comment: "") : NSLocalizedString("参与检索", comment: ""))
                            .etFont(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: memory.isArchived) { _, _ in
                    hasChanges = true
                }
            }

            Section(
                header: Text(NSLocalizedString("记忆属性", comment: "Memory attributes section")),
                footer: Text(NSLocalizedString("类型帮助模型理解用途；重要度和置信度会参与混合检索排序。", comment: "Memory attributes footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("类型", comment: "Memory kind field"), selection: $memory.kind) {
                    ForEach(MemoryKind.allCases, id: \.self) { kind in
                        Text(kind.localizedTitle).tag(kind)
                    }
                }
                .onChange(of: memory.kind) { _, _ in hasChanges = true }

                Text(String(format: NSLocalizedString("重要度：%.1f", comment: "Memory importance value"), memory.importance))
                    .etFont(.footnote)
                Slider(value: $memory.importance, in: 0...1, step: 0.1)
                    .onChange(of: memory.importance) { _, _ in hasChanges = true }

                Text(String(format: NSLocalizedString("置信度：%.1f", comment: "Memory confidence value"), memory.confidence))
                    .etFont(.footnote)
                Slider(value: $memory.confidence, in: 0...1, step: 0.1)
                    .onChange(of: memory.confidence) { _, _ in hasChanges = true }

                TextField(NSLocalizedString("相关实体（用逗号分隔）", comment: "Memory entities field"), text: entitiesBinding)
            }
            
            Section {
                HStack {
                    Text(NSLocalizedString("更新时间", comment: ""))
                        .etFont(.footnote)
                    Spacer()
                    Text(memory.displayDate.formatted(date: .abbreviated, time: .shortened))
                        .etFont(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Section(
                header: Text(NSLocalizedString("嵌入", comment: "Memory embedding section")),
                footer: Text(NSLocalizedString("如果当前页面有未保存更改，会先保存再重新嵌入。", comment: "Single memory reembedding footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
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
                        .etFont(.caption2)
                        .foregroundStyle(reembedStatusIsError ? .orange : .secondary)
                }
            }
            
            Section {
                Button(NSLocalizedString("保存更改", comment: ""), action: saveMemory)
                    .disabled(!canSaveChanges)
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

            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "Save")) {
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

    private var canSaveChanges: Bool {
        hasChanges && !isReembeddingMemory && !memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var entitiesBinding: Binding<String> {
        Binding(
            get: { memory.entities.joined(separator: ", ") },
            set: { value in
                memory.entities = value
                    .components(separatedBy: CharacterSet(charactersIn: ",，"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                hasChanges = true
            }
        )
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

    private var reembedButtonTitle: String {
        hasChanges
            ? NSLocalizedString("保存并重新嵌入", comment: "Save and reembed single memory")
            : NSLocalizedString("重新嵌入这条记忆", comment: "Reembed single memory")
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
