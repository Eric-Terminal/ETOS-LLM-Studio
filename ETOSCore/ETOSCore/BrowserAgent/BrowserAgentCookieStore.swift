// Browser Agent 仅在下载请求组装时读取当前 WebView 的 Cookie，避免暴露底层存储。

#if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
import Foundation
import WebKit

extension WKHTTPCookieStore {
    func browserAgentAllCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
#endif
