// ============================================================================
// MemorySettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了记忆库管理的主视图。
// 用户可以在此查看、添加、删除和编辑他们的长期记忆。
// ============================================================================

import SwiftUI
import Shared

public struct MemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingMemory = false

    public init() {}

    public var body: some View {
        // 检查 OS 版本是否支持记忆功能
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            memoryListView
                .navigationTitle("记忆库管理")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { isAddingMemory = true }) {
                            Image(systemName: "plus")
                        }
                    }
                }
                .sheet(isPresented: $isAddingMemory) {
                    AddMemorySheet()
                        .environmentObject(viewModel)
                }
        } else {
            // 对于不支持的旧版系统，显示提示信息
            Text("记忆库功能需要 watchOS 9.0 或更高版本。")
                .foregroundColor(.secondary)
                .navigationTitle("记忆库管理")
        }
    }

    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    private var memoryListView: some View {
        List {
            if viewModel.memories.isEmpty {
                Text("还没有任何记忆。")
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.memories) { memory in
                    NavigationLink(destination: MemoryEditView(memory: memory).environmentObject(viewModel)) {
                        VStack(alignment: .leading) {
                            Text(memory.content)
                                .lineLimit(2)
                            Text(memory.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteItems)
            }
        }
    }
    
    private func deleteItems(at offsets: IndexSet) {
        Task {
            await viewModel.deleteMemories(at: offsets)
        }
    }
}

/// 用于添加新记忆的表单视图
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) 
public struct AddMemorySheet: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    @State private var memoryContent: String = ""

    public init() {}

    public var body: some View {
        VStack {
            Text("添加新记忆")
                .font(.headline)
                .padding()

            TextField("输入记忆内容...", text: $memoryContent)
                .padding()

            Button("保存") {
                Task {
                    await viewModel.addMemory(content: memoryContent)
                    dismiss()
                }
            }
            .disabled(memoryContent.isEmpty)
        }
    }
}

// 预览
struct MemorySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        MemorySettingsView()
            .environmentObject(ChatViewModel())
    }
}
