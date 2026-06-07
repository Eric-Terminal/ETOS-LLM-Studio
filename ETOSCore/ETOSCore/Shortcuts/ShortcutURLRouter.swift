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

    private enum Route: String {
        case importRoute = "import"
        case callback = "callback"
        case templateStatus = "template-status"
    }

    private init() {}

    @discardableResult
    public func handleIncomingURL(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.appScheme else {
            return false
        }
        guard let route = resolveRoute(from: url) else {
            return false
        }

        let normalizedURL = normalizedShortcutURL(for: route, original: url)
        switch route {
        case .importRoute:
            _ = await ShortcutToolManager.shared.importFromClipboard(triggerURL: normalizedURL)
            return true
        case .callback:
            return ShortcutToolManager.shared.handleCallbackURL(normalizedURL)
        case .templateStatus:
            return ShortcutToolManager.shared.handleOfficialTemplateStatusURL(normalizedURL)
        }
    }

    private func resolveRoute(from url: URL) -> Route? {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathComponents = url.path
            .split(separator: "/")
            .map { $0.lowercased() }
        let acceptedShortcutHosts: Set<String> = ["shortcut", "shortcuts"]

        if let host, acceptedShortcutHosts.contains(host) {
            return pathComponents.first.flatMap(Route.init(rawValue:))
        }

        if host == nil || host?.isEmpty == true {
            guard pathComponents.count >= 2,
                  acceptedShortcutHosts.contains(pathComponents[0]) else {
                return nil
            }
            return Route(rawValue: pathComponents[1])
        }

        if let host, pathComponents.isEmpty {
            return Route(rawValue: host)
        }

        return nil
    }

    private func normalizedShortcutURL(for route: Route, original url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.host = "shortcuts"
        components.path = "/\(route.rawValue)"
        return components.url ?? url
    }
}
