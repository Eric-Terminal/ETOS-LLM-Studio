// ============================================================================
// RewriteMessageView.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息重写视图。
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
                TextField(
                    NSLocalizedString("输入重写要求", comment: "Message rewrite input placeholder"),
                    text: $instruction.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(4...10)
            } footer: {
                Text(NSLocalizedString("只会发送当前回复和重写要求。", comment: "Watch message rewrite footer"))
            }

            Section(NSLocalizedString("原文预览", comment: "Message rewrite original preview section")) {
                Text(message.content)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(NSLocalizedString("重写", comment: "Submit message rewrite")) {
                onSubmit(instruction)
                dismiss()
            }
            .disabled(!canSubmit)
        }
        .navigationTitle(NSLocalizedString("重写回复", comment: "Message rewrite navigation title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) {
                    dismiss()
                }
            }
        }
    }
}
