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
            Section("记忆内容") {
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: memory.isArchived) { _, _ in
                    hasChanges = true
                }
            } header: {
                Text("状态")
            }
            
            Section {
                LabeledContent("更新时间") {
                    Text(memory.displayDate.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("编辑记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
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
