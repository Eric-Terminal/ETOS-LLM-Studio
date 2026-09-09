import SwiftUI
import UIKit
import WebKit
import ETOSCore

private struct InlineHTMLMessageIdentityKey: EnvironmentKey {
    static let defaultValue: InlineHTMLMessageIdentity? = nil
}

struct InlineHTMLMessageIdentity {
    let messageID: UUID
    let versionIndex: Int
}

extension EnvironmentValues {
    var inlineHTMLMessageIdentity: InlineHTMLMessageIdentity? {
        get { self[InlineHTMLMessageIdentityKey.self] }
        set { self[InlineHTMLMessageIdentityKey.self] = newValue }
    }
}

@MainActor
enum InlineHTMLWebViewSupport {
    static func connect(_ content: InlineHTMLContent, to webView: WKWebView) {
        content.capturePNG = { [weak webView] in
            guard let webView, !webView.isLoading else { throw InlineHTMLExportError.notReady }
            // 内联酒馆视图已按内容展开，Widget 则以固定画布显示；直接取各自当前的完整画布。
            let size = webView.bounds.size
            let scale = webView.window?.screen.scale ?? 2
            try InlineHTMLExportSupport.validateSnapshotSize(size, scale: scale)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            configuration.afterScreenUpdates = true
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: configuration) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: InlineHTMLExportError.imageFailed) }
                }
            }
            guard let cgImage = image.cgImage else { throw InlineHTMLExportError.imageFailed }
            return try await Task.detached(priority: .userInitiated) {
                try InlineHTMLExportSupport.pngData(image: cgImage)
            }.value
        }
        content.readText = { [weak webView] in
            guard let webView, !webView.isLoading else { throw InlineHTMLExportError.notReady }
            return try await webView.evaluateJavaScript("document.body?.innerText ?? ''") as? String ?? ""
        }
        InlineHTMLContentRegistry.shared.register(content)
    }
}

struct InlineHTMLMessageActionsLink: View {
    let message: ChatMessage
    let contents: [InlineHTMLContent]

    var body: some View {
        if !contents.isEmpty {
            NavigationLink {
                if contents.count == 1, let content = contents.first {
                    InlineHTMLActionsView(content: content) { EmptyView() }
                } else {
                    List(contents) { content in
                        NavigationLink(content.title) {
                            InlineHTMLActionsView(content: content) { EmptyView() }
                        }
                    }
                    .navigationTitle(NSLocalizedString("内联内容", comment: ""))
                    .guideSettingsPageContext(
                        id: GuidePageID(rawValue: "inline-html-list-\(message.id)"),
                        title: NSLocalizedString("内联内容", comment: ""),
                        documents: [GuideDocumentReference(id: "inline-html-actions", title: NSLocalizedString("内联内容", comment: ""))],
                        settings: [.readOnly("count", label: NSLocalizedString("内联内容", comment: ""), value: { .int(contents.count) })]
                    )
                }
            } label: {
                Label(NSLocalizedString("内联内容", comment: ""), systemImage: "curlybraces.square")
            }
        }
    }
}
