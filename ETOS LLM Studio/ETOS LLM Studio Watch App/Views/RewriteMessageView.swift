// ============================================================================
// RewriteMessageView.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息重写视图。
// ============================================================================

import SwiftUI
import Shared

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
                TextField(
                    NSLocalizedString("输入重写要求", comment: "Message rewrite input placeholder"),
                    text: $instruction.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(4...10)
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
                NavigationLink {
                    RewriteMessageOriginalPreviewView(content: message.content)
                } label: {
                    Label(
                        NSLocalizedString("原文预览", comment: "Message rewrite original preview section"),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("重写回复", comment: "Message rewrite navigation title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("重写", comment: "Submit message rewrite")) {
                    submitRewrite()
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
            return NSLocalizedString("只会发送当前回复和重写要求。", comment: "Watch message rewrite footer")
        }
        return NSLocalizedString("会发送当前回复、重写要求以及你勾选的其他版本。", comment: "Watch message rewrite footer with reference versions")
    }

    private func rewriteReferenceVersionRow(_ version: MessageRewriteReferenceVersion) -> some View {
        let isSelected = selectedReferenceVersionNumbers.contains(version.versionNumber)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("版本 %d", comment: ""), version.versionNumber))
                    .foregroundStyle(.primary)
                Text(version.content)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func submitRewrite() {
        onSubmit(instruction, selectedReferenceVersions)
        dismiss()
    }
}

private struct RewriteMessageOriginalPreviewView: View {
    let content: String

    var body: some View {
        List {
            Text(content)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("原文预览", comment: "Message rewrite original preview section"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
