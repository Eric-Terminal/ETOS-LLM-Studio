import SwiftUI
import ETOSCore
import UIKit

/// 与手表既有 WebKit 承载层一样，仅在运行时桥接系统未公开的 WebKit 接口。
enum WatchInlineHTMLExportSupport {
    static func connect(_ content: InlineHTMLContent, to webView: NSObject) {
        content.capturePNG = { [weak webView] in
            let selector = NSSelectorFromString("takeSnapshotWithConfiguration:completionHandler:")
            guard let webView, webView.responds(to: selector),
                  webView.value(forKey: "loading") as? Bool == false,
                  let bounds = webView.value(forKey: "bounds") as? NSValue else {
                throw InlineHTMLExportError.notReady
            }
            try InlineHTMLExportSupport.validateSnapshotSize(bounds.cgRectValue.size, scale: 2)
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                let completion: @convention(block) (UIImage?, NSError?) -> Void = { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: InlineHTMLExportError.imageFailed) }
                }
                _ = webView.perform(selector, with: nil, with: completion as AnyObject)
            }
            guard let cgImage = image.cgImage else { throw InlineHTMLExportError.imageFailed }
            return try await Task.detached(priority: .userInitiated) {
                try InlineHTMLExportSupport.pngData(image: cgImage)
            }.value
        }
        content.readText = { [weak webView] in
            let selector = NSSelectorFromString("evaluateJavaScript:completionHandler:")
            guard let webView, webView.responds(to: selector),
                  webView.value(forKey: "loading") as? Bool == false else {
                throw InlineHTMLExportError.notReady
            }
            return try await withCheckedThrowingContinuation { continuation in
                let completion: @convention(block) (Any?, NSError?) -> Void = { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
                _ = webView.perform(selector, with: "document.body?.innerText ?? ''" as NSString, with: completion as AnyObject)
            }
        }
    }
}

struct WatchInlineHTMLActionsPage: View {
    let content: InlineHTMLContent
    let onCopy: (String) -> Void
    @State private var needsPreview: Bool

    init(content: InlineHTMLContent, onCopy: @escaping (String) -> Void) {
        self.content = content
        self.onCopy = onCopy
        _needsPreview = State(initialValue: content.capturePNG == nil)
    }

    var body: some View {
        InlineHTMLActionsView(content: content, onCopy: onCopy) {
            if needsPreview {
                Section {
                    WatchRuntimeHTMLWebView(html: content.html, inlineContent: content)
                        .frame(height: 180)
                }
            }
        }
        .watchGuideEntry()
    }
}

struct WatchInlineWidgetCard: View {
    let payload: ToolWidgetPayload
    let messageID: UUID
    let versionIndex: Int
    let onOpen: (WatchWebHTMLPageItem) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var content = InlineHTMLContent()
    @State private var isPrepared = false

    var body: some View {
        Button {
            onOpen(WatchWebHTMLPageItem(title: content.title, html: content.html, inlineContent: content))
        } label: {
            HStack {
                Text(payload.title ?? NSLocalizedString("可视化 Widget", comment: ""))
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.forward")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isPrepared)
        .task(id: PreparationID(payload: payload, dark: colorScheme == .dark, version: versionIndex)) {
            let payload = payload
            let dark = colorScheme == .dark
            let html = await Task.detached(priority: .utility) {
                WatchWebHTMLDocumentFactory.widgetDocument(payload: payload, prefersDarkPalette: dark)
            }.value
            guard !Task.isCancelled else { return }
            content.messageID = messageID
            content.versionIndex = versionIndex
            content.title = payload.title ?? NSLocalizedString("可视化 Widget", comment: "")
            content.code = payload.widgetCode
            content.html = html
            InlineHTMLContentRegistry.shared.register(content)
            isPrepared = true
        }
    }

    private struct PreparationID: Equatable {
        let payload: ToolWidgetPayload
        let dark: Bool
        let version: Int
    }
}
