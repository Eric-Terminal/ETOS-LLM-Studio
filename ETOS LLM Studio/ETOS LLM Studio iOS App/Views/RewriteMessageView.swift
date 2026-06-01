// ============================================================================
// RewriteMessageView.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天消息重写输入界面 (iOS)。
// ============================================================================

import SwiftUI
import Shared

struct RewriteMessageView: View {
    let message: ChatMessage
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instruction: String = ""

    private var canSubmit: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("重写要求", comment: "Message rewrite instruction section")) {
                TextEditor(text: $instruction)
                    .frame(minHeight: 140)
            } footer: {
                Text(NSLocalizedString("只会把当前这条回复和重写要求发送给 AI，不会附带历史上下文。", comment: "Message rewrite footer"))
            }

            Section(NSLocalizedString("原文预览", comment: "Message rewrite original preview section")) {
                Text(message.content)
                    .etFont(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(NSLocalizedString("重写回复", comment: "Message rewrite navigation title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("重写", comment: "Submit message rewrite")) {
                    onSubmit(instruction)
                    dismiss()
                }
                .disabled(!canSubmit)
            }
        }
    }
}
