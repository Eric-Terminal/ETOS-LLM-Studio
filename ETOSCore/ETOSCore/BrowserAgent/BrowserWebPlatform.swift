import Foundation

enum BrowserWebPlatform {
    #if os(macOS)
    static let name = "macOS"
    static let defaultViewport = CGSize(width: 1024, height: 768)
    #else
    static let name = "iOS"
    static let defaultViewport = CGSize(width: 390, height: 844)
    #endif

    /// 桌面与重置使用 WebKit 自身版本；移动标识仅用于网站布局选择，不模拟设备能力。
    static func userAgent(for profile: BrowserAgentUserAgentProfile) -> String? {
        guard profile == .mobileSafari else { return nil }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    }
}
