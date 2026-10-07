import AppKit
import ETOSCore
import WebKit

@MainActor
enum MacInlineHTMLWebViewSupport {
    static func connect(_ content: InlineHTMLContent, to webView: WKWebView) {
        content.capturePNG = { [weak webView] in
            guard let webView, !webView.isLoading else { throw InlineHTMLExportError.notReady }
            let size = webView.bounds.size
            try InlineHTMLExportSupport.validateSnapshotSize(size, scale: webView.window?.backingScaleFactor ?? 2)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: configuration) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: InlineHTMLExportError.imageFailed) }
                }
            }
            guard let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw InlineHTMLExportError.imageFailed }
            return try await Task.detached(priority: .userInitiated) { try InlineHTMLExportSupport.pngData(image: image) }.value
        }
        content.readText = { [weak webView] in
            guard let webView, !webView.isLoading else { throw InlineHTMLExportError.notReady }
            return try await webView.evaluateJavaScript("document.body?.innerText ?? ''") as? String ?? ""
        }
        InlineHTMLContentRegistry.shared.register(content)
    }
}
