import SwiftUI
import Shared

struct MemorySettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingMemory = false
    @State private var isReembeddingMemories = false
    @State private var showReembedConfirmation = false
    @State private var reembedAlert: MemoryReembedAlert?
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
            
            Section("数据维护") {
                Button(role: .destructive) {
                    showReembedConfirmation = true
                } label: {
                    HStack {
                        Label("重新生成全部嵌入", systemImage: "arrow.triangle.2.circlepath")
                        if isReembeddingMemories {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isReembeddingMemories)
            } footer: {
                Text("会清理旧的向量数据库并为所有记忆重新生成嵌入。完成后历史检索将使用最新数据。")
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
        .confirmationDialog(
            "重新嵌入全部记忆？",
            isPresented: $showReembedConfirmation,
            titleVisibility: .visible
        ) {
            Button("重新嵌入", role: .destructive) {
                triggerFullReembed()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除旧的 SQLite 向量数据库，并基于当前记忆原文重新生成嵌入。")
        }
        .alert(item: $reembedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好的"))
            )
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
    
    private func triggerFullReembed() {
        guard !isReembeddingMemories else { return }
        isReembeddingMemories = true
        
        Task {
            do {
                let summary = try await viewModel.reembedAllMemories()
                await MainActor.run {
                    reembedAlert = MemoryReembedAlert.success(summary: summary)
                    isReembeddingMemories = false
                }
            } catch {
                await MainActor.run {
                    reembedAlert = MemoryReembedAlert.failure(message: error.localizedDescription)
                    isReembeddingMemories = false
                }
            }
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

private struct MemoryReembedAlert: Identifiable {
    enum Kind {
        case success(MemoryReembeddingSummary)
        case failure(String)
    }
    
    let id = UUID()
    let kind: Kind
    
    var title: String {
        switch kind {
        case .success:
            return "重新嵌入完成"
        case .failure:
            return "重新嵌入失败"
        }
    }
    
    var message: String {
        switch kind {
        case .success(let summary):
            return "共处理 \(summary.processedMemories) 条记忆，生成 \(summary.chunkCount) 个分块。"
        case .failure(let message):
            return message
        }
    }
    
    static func success(summary: MemoryReembeddingSummary) -> MemoryReembedAlert {
        MemoryReembedAlert(kind: .success(summary))
    }
    
    static func failure(message: String) -> MemoryReembedAlert {
        MemoryReembedAlert(kind: .failure(message))
    }
}
