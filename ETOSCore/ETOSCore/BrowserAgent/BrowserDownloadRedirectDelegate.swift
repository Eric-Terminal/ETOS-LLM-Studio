// ============================================================================
// BrowserDownloadRedirectDelegate.swift
// ============================================================================
// ETOS LLM Studio
//
// 下载只跟随用户已经批准的来源域名；跨域目标交回 Browser Agent 的审批链。
// ============================================================================

import Foundation

#if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
final class BrowserDownloadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let lock = NSLock()
    private var blockedHostStorage: String?

    init(allowedHosts: Set<String>) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
    }

    var blockedHost: String? {
        lock.lock()
        defer { lock.unlock() }
        return blockedHostStorage
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            lock.lock()
            blockedHostStorage = request.url?.host?.lowercased()
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
#endif
