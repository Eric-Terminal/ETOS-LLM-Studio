import SwiftUI
import Shared

struct MemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingMemory = false
    @AppStorage("memoryTopK") private var memoryTopK: Int = 3
    
    private var embeddingModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedEmbeddingModel },
            set: { viewModel.setSelectedEmbeddingModel($0) }
        )
    }
    
    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
    
    var body: some View {
        Form {
            Section {
                let options = viewModel.embeddingModelOptions
                if options.isEmpty {
                    Text("暂无可用模型，请先在“数据与模型设置”中启用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("嵌入模型", selection: embeddingModelBinding) {
                        Text("未选择").tag(Optional<RunnableModel>.none)
                        ForEach(options) { runnable in
                            Text("\(runnable.model.displayName) | \(runnable.provider.name)")
                                .tag(Optional<RunnableModel>.some(runnable))
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("嵌入模型")
            } footer: {
                Text("列出当前配置的所有模型，记忆嵌入请求会使用所选模型发送。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("检索数量 (Top K)") {
                    TextField("0 表示不限制", value: $memoryTopK, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: memoryTopK) { newValue in
                            memoryTopK = max(0, newValue)
                        }
                }
            } header: {
                Text("检索设置")
            } footer: {
                Text("设置为 0 表示跳过检索，直接把所有记忆原文注入上下文。默认为 3。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section("记忆列表") {
                if viewModel.memories.isEmpty {
                    ContentUnavailableView(
                        "暂无记忆",
                        systemImage: "brain.head.profile",
                        description: Text("发送对话时可以让 AI 通过工具主动写入新的记忆。")
                    )
                } else {
                    ForEach(viewModel.memories) { memory in
                        NavigationLink {
                            MemoryEditView(memory: memory).environmentObject(viewModel)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(memory.content)
                                    .lineLimit(2)
                                Text(memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
            }
        }
        .navigationTitle("记忆库管理")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isAddingMemory = true
                } label: {
                    Label("添加记忆", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingMemory) {
            NavigationStack {
                AddMemorySheet()
                    .environmentObject(viewModel)
            }
        }
    }
    
    private func deleteItems(at offsets: IndexSet) {
        Task {
            await viewModel.deleteMemories(at: offsets)
        }
    }
}

struct AddMemorySheet: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var memoryContent: String = ""
    
    var body: some View {
        Form {
            Section("记忆内容") {
                TextField("输入要记住的信息…", text: $memoryContent, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle("添加记忆")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task {
                        await viewModel.addMemory(content: memoryContent)
                        dismiss()
                    }
                }
                .disabled(memoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
