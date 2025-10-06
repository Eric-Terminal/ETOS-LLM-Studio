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

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct MemoryEditView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var memory: MemoryItem
    
    public init(memory: MemoryItem) {
        _memory = State(initialValue: memory)
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("记忆内容")) {
                    TextField("在此输入多行记忆内容...", text: $memory.content, axis: .vertical)
                }
                
                Section {
                    Button("保存", action: saveMemory)
                }
            }
            .navigationTitle("编辑记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
    
    private func saveMemory() {
        Task {
            await viewModel.updateMemory(item: memory)
            dismiss()
        }
    }
}
