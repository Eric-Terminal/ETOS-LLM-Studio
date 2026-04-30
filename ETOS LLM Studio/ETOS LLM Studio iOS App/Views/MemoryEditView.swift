// ============================================================================
// MemoryEditView.swift
// ============================================================================
// MemoryEditView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Shared

struct MemoryEditView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var memory: MemoryItem
    @State private var hasChanges = false
    
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
        }
        .navigationTitle(NSLocalizedString("编辑记忆", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(NSLocalizedString("保存", comment: "")) {
                    Task {
                        await viewModel.updateMemory(item: memory)
                        dismiss()
                    }
                }
                .disabled(!hasChanges || memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
