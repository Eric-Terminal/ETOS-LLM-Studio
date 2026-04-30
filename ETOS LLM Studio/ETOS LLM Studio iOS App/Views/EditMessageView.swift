// ============================================================================
// EditMessageView.swift
// ============================================================================
// EditMessageView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

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
            Section(NSLocalizedString("消息内容", comment: "")) {
                TextEditor(text: $content)
                    .frame(minHeight: 160)
            }
            
            if message.role == .assistant {
                Section(NSLocalizedString("思考过程", comment: "")) {
                    TextEditor(text: $reasoning)
                        .frame(minHeight: 120)
                }
            }
        }
        .navigationTitle(NSLocalizedString("编辑消息", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
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
