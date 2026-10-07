import AppKit
import SwiftUI

/// AppKit 只负责选择已准备好的纯文本，UTF-16 到 Markdown 的映射由后台模型处理。
struct MacSelectableMessageText: NSViewRepresentable {
    let documentID: UUID
    let text: String
    let selectionChanged: (NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selectionChanged: selectionChanged) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selectionChanged = selectionChanged
        guard context.coordinator.documentID != documentID, let textView = scroll.documentView as? NSTextView else { return }
        // 使用文档标识避免每次状态变化都比较或重新设置长文本。
        context.coordinator.documentID = documentID
        context.coordinator.isUpdatingDocument = true
        defer { context.coordinator.isUpdatingDocument = false }
        textView.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var documentID: UUID?
        var isUpdatingDocument = false
        var selectionChanged: (NSRange) -> Void
        init(selectionChanged: @escaping (NSRange) -> Void) { self.selectionChanged = selectionChanged }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingDocument, let textView = notification.object as? NSTextView else { return }
            selectionChanged(textView.selectedRange())
        }
    }
}
