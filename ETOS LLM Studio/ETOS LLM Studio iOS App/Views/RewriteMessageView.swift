// ============================================================================
// RewriteMessageView.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天消息重写输入界面 (iOS)。
// ============================================================================

import SwiftUI
import ETOSCore

struct RewriteMessageView: View {
    let message: ChatMessage
    let referenceVersions: [MessageRewriteReferenceVersion]
    let onSubmit: (String, [MessageRewriteReferenceVersion]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instruction: String = ""
    @State private var selectedReferenceVersionNumbers: Set<Int> = []

    private var canSubmit: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedReferenceVersions: [MessageRewriteReferenceVersion] {
        referenceVersions.filter { selectedReferenceVersionNumbers.contains($0.versionNumber) }
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $instruction)
                    .frame(minHeight: 140)
            } header: {
                Text(NSLocalizedString("重写要求", comment: "Message rewrite instruction section"))
            } footer: {
                Text(rewriteFooterText)
            }

            if !referenceVersions.isEmpty {
                Section {
                    ForEach(referenceVersions) { version in
                        Button {
                            toggleReferenceVersion(version.versionNumber)
                        } label: {
                            rewriteReferenceVersionRow(version)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(NSLocalizedString("参考其他版本", comment: "Message rewrite reference versions section"))
                } footer: {
                    Text(NSLocalizedString("勾选后会把这些版本随重写要求一起发送。你可以在要求里说明想吸收某个版本的优点。", comment: "Message rewrite reference versions footer"))
                }
            }

            Section {
                Text(message.content)
                    .etFont(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text(NSLocalizedString("原文预览", comment: "Message rewrite original preview section"))
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
                    onSubmit(instruction, selectedReferenceVersions)
                    dismiss()
                }
                .disabled(!canSubmit)
            }
        }
    }

    private func toggleReferenceVersion(_ versionNumber: Int) {
        if selectedReferenceVersionNumbers.contains(versionNumber) {
            selectedReferenceVersionNumbers.remove(versionNumber)
        } else {
            selectedReferenceVersionNumbers.insert(versionNumber)
        }
    }

    private var rewriteFooterText: String {
        if referenceVersions.isEmpty {
            return NSLocalizedString("只会把当前这条回复和重写要求发送给 AI，不会附带历史上下文。", comment: "Message rewrite footer")
        }
        return NSLocalizedString("会发送当前回复、重写要求以及你勾选的其他版本，不会附带历史上下文。", comment: "Message rewrite footer with reference versions")
    }

    private func rewriteReferenceVersionRow(_ version: MessageRewriteReferenceVersion) -> some View {
        let isSelected = selectedReferenceVersionNumbers.contains(version.versionNumber)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.system(size: 20))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: NSLocalizedString("版本 %d", comment: ""), version.versionNumber))
                    .foregroundStyle(.primary)
                Text(version.content)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
    }
}
