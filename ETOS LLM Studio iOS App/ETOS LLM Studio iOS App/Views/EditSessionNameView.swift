import SwiftUI
import Shared

struct EditSessionNameView: View {
    @Binding var session: ChatSession
    var onSave: () -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    
    init(session: Binding<ChatSession>, onSave: @escaping () -> Void) {
        _session = session
        self.onSave = onSave
        _name = State(initialValue: session.wrappedValue.name)
    }
    
    var body: some View {
        Form {
            Section("会话名称") {
                TextField("输入新名称", text: $name)
            }
        }
        .navigationTitle("编辑话题")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    session.name = name
                    onSave()
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
