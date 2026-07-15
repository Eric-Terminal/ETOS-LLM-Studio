// ============================================================================
// MessageTextSelectionView.swift
// ============================================================================
// iOS 消息文字选择页：系统负责局部选区，工具栏负责整条内容复制。
// ============================================================================

import SwiftUI
import Foundation
import UIKit
import ETOSCore

struct MessageTextSelectionView: View {
    let message: ChatMessage

    @State private var plainText: String?
    @State private var showsCopyFormatDialog = false

    var body: some View {
        Group {
            if let plainText {
                MessageSelectableTextView(text: plainText)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .navigationTitle(NSLocalizedString("选定文字", comment: "Message text selection title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsCopyFormatDialog = true
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(NSLocalizedString("复制内容", comment: "Copy full message content"))
                .disabled(plainText == nil)
            }
        }
        .confirmationDialog(
            NSLocalizedString("复制格式", comment: "Copy format dialog title"),
            isPresented: $showsCopyFormatDialog,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("复制为 Markdown", comment: "Copy message as Markdown")) {
                copyToPasteboard(message.content)
            }
            Button(NSLocalizedString("复制为纯文本", comment: "Copy message as plain text")) {
                copyToPasteboard(plainText ?? message.content)
            }
            Button(NSLocalizedString("取消", comment: "Cancel copy format selection"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("选择需要复制的格式。", comment: "Copy format dialog guidance"))
        }
        .task(id: message.id) {
            let markdown = message.content
            let prepared = await Task.detached(priority: .userInitiated) {
                MessageTextSelectionSupport.plainText(fromMarkdown: markdown)
            }.value
            guard !Task.isCancelled else { return }
            plainText = prepared
        }
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// UITextView 在可拖拽 Sheet 中仍由系统完整处理长按、选区拖动与复制菜单。
struct MessageSelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        Self.makeTextView(text: text)
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.text != text else { return }
        textView.text = text
    }

    @MainActor
    static func makeTextView(text: String) -> UITextView {
        let textView = UITextView()
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }
}
