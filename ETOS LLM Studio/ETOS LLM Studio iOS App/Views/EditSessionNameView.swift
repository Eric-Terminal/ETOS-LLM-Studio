// ============================================================================
// EditSessionNameView.swift
// ============================================================================
// EditSessionNameView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

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
            Section(NSLocalizedString("会话名称", comment: "")) {
                TextField(NSLocalizedString("输入新名称", comment: ""), text: $name)
            }
        }
        .navigationTitle(NSLocalizedString("编辑话题", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    session.name = name
                    onSave()
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
