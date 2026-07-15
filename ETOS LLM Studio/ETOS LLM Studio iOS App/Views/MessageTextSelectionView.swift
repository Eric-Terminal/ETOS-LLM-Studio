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
    let onRewriteSelection: ((MessageRewriteSelectionTarget) -> Void)?
    let onAskAI: (String) -> Void

    @State private var selectableDocument: MessageSelectableTextDocument?
    @State private var showsCopyFormatDialog = false
    @State private var showsSelectionMappingError = false

    init(
        message: ChatMessage,
        onRewriteSelection: ((MessageRewriteSelectionTarget) -> Void)? = nil,
        onAskAI: @escaping (String) -> Void
    ) {
        self.message = message
        self.onRewriteSelection = onRewriteSelection
        self.onAskAI = onAskAI
    }

    var body: some View {
        Group {
            if let selectableDocument {
                MessageSelectableTextView(
                    text: selectableDocument.plainText,
                    onAskAI: onAskAI,
                    onRewriteSelection: onRewriteSelection.map { callback in
                        { range in
                            resolveRewriteSelection(
                                range,
                                document: selectableDocument,
                                callback: callback
                            )
                        }
                    }
                )
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
                .disabled(selectableDocument == nil)
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
                copyToPasteboard(selectableDocument?.plainText ?? message.content)
            }
            Button(NSLocalizedString("取消", comment: "Cancel copy format selection"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("选择需要复制的格式。", comment: "Copy format dialog guidance"))
        }
        .alert(
            NSLocalizedString("无法重写这个选区", comment: "Selection rewrite mapping failure title"),
            isPresented: $showsSelectionMappingError
        ) {
            Button(NSLocalizedString("好的", comment: "Dismiss selection rewrite mapping failure"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("这个选区包含无法安全对应到原始 Markdown 的内容，请缩小选区后重试。", comment: "Selection rewrite mapping failure guidance"))
        }
        .task(id: message.id) {
            let markdown = message.content
            let prepared = await Task.detached(priority: .userInitiated) {
                MessageTextSelectionSupport.selectableDocument(fromMarkdown: markdown)
            }.value
            guard !Task.isCancelled else { return }
            selectableDocument = prepared
        }
    }

    private func resolveRewriteSelection(
        _ range: Range<Int>,
        document: MessageSelectableTextDocument,
        callback: @escaping (MessageRewriteSelectionTarget) -> Void
    ) {
        Task { @MainActor in
            let target = await Task.detached(priority: .userInitiated) {
                document.rewriteTarget(displayUTF16Range: range)
            }.value
            guard let target else {
                showsSelectionMappingError = true
                return
            }
            callback(target)
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
    let onAskAI: (String) -> Void
    let onRewriteSelection: ((Range<Int>) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onAskAI: onAskAI,
            onRewriteSelection: onRewriteSelection
        )
    }

    func makeUIView(context: Context) -> UITextView {
        Self.makeTextView(text: text, delegate: context.coordinator)
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onAskAI = onAskAI
        context.coordinator.onRewriteSelection = onRewriteSelection
        guard textView.text != text else { return }
        textView.text = text
    }

    @MainActor
    static func makeTextView(text: String, delegate: UITextViewDelegate? = nil) -> UITextView {
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
        textView.delegate = delegate
        return textView
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onAskAI: (String) -> Void
        var onRewriteSelection: ((Range<Int>) -> Void)?

        init(
            onAskAI: @escaping (String) -> Void,
            onRewriteSelection: ((Range<Int>) -> Void)? = nil
        ) {
            self.onAskAI = onAskAI
            self.onRewriteSelection = onRewriteSelection
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.location != NSNotFound,
                  range.length > 0,
                  NSMaxRange(range) <= textView.textStorage.length else {
                return nil
            }

            let sourceText = textView.text ?? ""
            let rangeLocation = range.location
            let rangeLength = range.length
            let askAction = UIAction(
                title: NSLocalizedString("询问 AI", comment: "Ask AI about selected message text"),
                image: UIImage(systemName: "sparkles")
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    let selectedText = await Task.detached(priority: .userInitiated) {
                        (sourceText as NSString).substring(
                            with: NSRange(location: rangeLocation, length: rangeLength)
                        )
                    }.value
                    self?.onAskAI(selectedText)
                }
            }
            var customActions: [UIMenuElement] = [askAction]
            if onRewriteSelection != nil {
                let rewriteAction = UIAction(
                    title: NSLocalizedString("重写选区", comment: "Rewrite selected assistant message text"),
                    image: UIImage(systemName: "wand.and.stars")
                ) { [weak self] _ in
                    self?.onRewriteSelection?(rangeLocation..<(rangeLocation + rangeLength))
                }
                customActions.append(rewriteAction)
            }
            return UIMenu(children: customActions + suggestedActions)
        }
    }
}
