// ============================================================================
// MemoryEditView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了记忆编辑视图。
// 用户可以在此修改单条记忆的具体内容。
// ============================================================================

import SwiftUI
import Shared

public struct MemoryEditView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var memory: MemoryItem
    @State private var hasChanges = false
    
    public init(memory: MemoryItem) {
        _memory = State(initialValue: memory)
    }
    
    public var body: some View {
        Form {
            Section(header: Text("记忆内容")) {
                TextField("在此输入多行记忆内容...", text: $memory.content, axis: .vertical)
                    .lineLimit(5...20)
                    .onChange(of: memory.content) { _, _ in
                        hasChanges = true
                    }
            }
            
            Section(header: Text("状态")) {
                Toggle(isOn: $memory.isArchived) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memory.isArchived ? NSLocalizedString("已归档", comment: "") : NSLocalizedString("激活中", comment: ""))
                            .font(.footnote)
                        Text(memory.isArchived ? NSLocalizedString("不参与检索", comment: "") : NSLocalizedString("参与检索", comment: ""))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: memory.isArchived) { _, _ in
                    hasChanges = true
                }
            }
            
            Section {
                HStack {
                    Text("更新时间")
                        .font(.footnote)
                    Spacer()
                    Text(memory.displayDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Section {
                Button("保存更改", action: saveMemory)
                    .disabled(!hasChanges || memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("编辑记忆")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func saveMemory() {
        Task {
            await viewModel.updateMemory(item: memory)
            dismiss()
        }
    }
}
