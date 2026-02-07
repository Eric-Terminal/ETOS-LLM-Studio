// ============================================================================
// ShortcutURLRouter.swift
// ============================================================================
// 自定义 URL Scheme 路由
// ============================================================================

import Foundation

@MainActor
public final class ShortcutURLRouter {
    public static let shared = ShortcutURLRouter()
    public static let appScheme = "etosllmstudio"

    private init() {}

    @discardableResult
    public func handleIncomingURL(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.appScheme else {
            return false
        }
        guard url.host?.lowercased() == "shortcuts" else {
            return false
        }

        let path = url.path.lowercased()
        switch path {
        case "/import":
            _ = await ShortcutToolManager.shared.importFromClipboard(triggerURL: url)
            return true
        case "/callback":
            return ShortcutToolManager.shared.handleCallbackURL(url)
        default:
            return false
        }
    }
}
