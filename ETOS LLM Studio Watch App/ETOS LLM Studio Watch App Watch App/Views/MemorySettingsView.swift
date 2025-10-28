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
    @AppStorage("memoryTopK") var memoryTopK: Int = 3

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    public init() {}

    public var body: some View {
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
    }

    private var memoryListView: some View {
        List {
            Section(header: Text("检索设置")) {
                HStack {
                    Text("检索数量 (Top K)")
                    Spacer()
                    TextField("数量", value: $memoryTopK, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }

            Text("设置为 0 表示加载全部记忆。默认值为 3。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: -8, leading: 12, bottom: 12, trailing: 12))
                .listRowBackground(Color.clear)

            Section(header: Text("记忆列表")) {
                if viewModel.memories.isEmpty {
                    Text("还没有任何记忆。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.memories) { memory in
                        NavigationLink(destination: MemoryEditView(memory: memory).environmentObject(viewModel)) {
                            VStack(alignment: .leading) {
                                Text(memory.content)
                                    .lineLimit(2)
                                Text(memory.createdAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
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
