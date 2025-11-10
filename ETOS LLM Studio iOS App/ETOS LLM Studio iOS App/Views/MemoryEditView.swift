import SwiftUI
import Shared

struct MemoryEditView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var memory: MemoryItem
    
    init(memory: MemoryItem) {
        _memory = State(initialValue: memory)
    }
    
    var body: some View {
        Form {
            Section("记忆内容") {
                TextEditor(text: $memory.content)
                    .frame(minHeight: 180)
            }
        }
        .navigationTitle("编辑记忆")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("退出") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task {
                        await viewModel.updateMemory(item: memory)
                        dismiss()
                    }
                }
                .disabled(memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
