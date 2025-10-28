import SwiftUI
import Shared

struct EditMessageView: View {
    let message: ChatMessage
    let onSave: (ChatMessage) -> Void
    @State private var content: String
    @State private var reasoning: String
    @Environment(\.dismiss) private var dismiss
    
    init(message: ChatMessage, onSave: @escaping (ChatMessage) -> Void) {
        self.message = message
        self.onSave = onSave
        _content = State(initialValue: message.content)
        _reasoning = State(initialValue: message.reasoningContent ?? "")
    }
    
    var body: some View {
        Form {
            Section("消息内容") {
                TextEditor(text: $content)
                    .frame(minHeight: 160)
            }
            
            if message.role == .assistant {
                Section("思考过程") {
                    TextEditor(text: $reasoning)
                        .frame(minHeight: 120)
                }
            }
        }
        .navigationTitle("编辑消息")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    var updated = message
                    updated.content = content
                    updated.reasoningContent = reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reasoning
                    onSave(updated)
                    dismiss()
                }
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
