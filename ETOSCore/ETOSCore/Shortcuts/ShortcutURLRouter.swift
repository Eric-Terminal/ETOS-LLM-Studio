// ============================================================================
// ShortcutURLRouter.swift
// ============================================================================
// 自定义 URL Scheme 路由
// ============================================================================

import Foundation

@MainActor
public final class ShortcutURLRouter {
    public static let shared = ShortcutURLRouter()
    nonisolated public static let appScheme = "etosllmstudio"

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

public struct NewAPIProviderImportResult {
    public var providerName: String
    public var summary: SyncMergeSummary
}

public enum NewAPIProviderImportError: LocalizedError {
    case unsupportedURL
    case invalidData
    case missingBaseURL
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return NSLocalizedString("无法识别 New API 导入链接。", comment: "New API deeplink import unsupported URL")
        case .invalidData:
            return NSLocalizedString("导入链接中的 data 不是有效的 Base64 JSON。", comment: "New API deeplink import invalid data")
        case .missingBaseURL:
            return NSLocalizedString("导入链接缺少 API 地址。", comment: "New API deeplink import missing base URL")
        case .missingAPIKey:
            return NSLocalizedString("导入链接缺少 API Key。", comment: "New API deeplink import missing API key")
        }
    }
}

public extension Notification.Name {
    static let newAPIProviderImportDidFinish = Notification.Name("newAPIProviderImportDidFinish")
    static let newAPIProviderImportDidFail = Notification.Name("newAPIProviderImportDidFail")
}

public enum NewAPIProviderImportURLHandler {
    public static func canHandle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ShortcutURLRouter.appScheme else {
            return false
        }
        let parts = routeParts(from: url)
        return parts == ["provider", "install"]
            || parts == ["provider", "add"]
            || parts == ["providers", "api-keys"]
            || parts == ["providers", "install"]
    }

    public static func importProvider(from url: URL) async throws -> NewAPIProviderImportResult {
        let provider = try await Task.detached(priority: .userInitiated) {
            try parseProvider(from: url)
        }.value
        let package = SyncPackage(
            options: [.providers],
            sourcePlatform: "New API",
            providers: [provider]
        )
        let summary = await Task.detached(priority: .userInitiated) {
            await SyncEngine.apply(package: package)
        }.value
        return NewAPIProviderImportResult(providerName: provider.name, summary: summary)
    }

    static func parseProvider(from url: URL) throws -> Provider {
        guard canHandle(url) else {
            throw NewAPIProviderImportError.unsupportedURL
        }

        let query = queryItems(from: url)
        let payload = try decodedPayload(from: query["data"])
        guard let baseURL = firstNonEmptyValue(
            in: payload,
            query: query,
            keys: ["baseUrl", "baseURL", "base_url", "url", "address", "apiHost", "api_host"]
        ) else {
            throw NewAPIProviderImportError.missingBaseURL
        }
        guard let apiKey = firstNonEmptyValue(
            in: payload,
            query: query,
            keys: ["apiKey", "api_key", "key", "token"]
        ) else {
            throw NewAPIProviderImportError.missingAPIKey
        }

        let typeHint = firstNonEmptyValue(
            in: payload,
            query: query,
            keys: ["apiFormat", "api_format", "type", "platform", "id"]
        )
        let providerName = firstNonEmptyValue(
            in: payload,
            query: query,
            keys: ["name", "providerName", "provider_name"]
        ) ?? "New API"
        let apiFormat = ThirdPartyImportService.normalizeProviderFormat(
            typeHint: typeHint,
            modelIDs: []
        )
        let normalizedBaseURL = ThirdPartyImportService.normalizeBaseURL(baseURL, for: apiFormat)
        let providerID = ThirdPartyImportService.stableUUID(
            from: "new-api-provider:\(providerName.lowercased()):\(normalizedBaseURL.lowercased())"
        ) ?? UUID()

        return Provider(
            id: providerID,
            name: providerName,
            baseURL: normalizedBaseURL,
            apiKeys: ThirdPartyImportService.splitAPIKeys(apiKey),
            apiFormat: apiFormat
        )
    }

    private static func routeParts(from url: URL) -> [String] {
        var parts: [String] = []
        if let host = ThirdPartyImportService.nonEmpty(url.host?.lowercased()) {
            parts.append(host)
        }
        parts.append(contentsOf: url.path
            .split(separator: "/")
            .map { $0.lowercased() }
        )
        return parts
    }

    private static func queryItems(from url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in items {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private static func decodedPayload(from rawData: String?) throws -> [String: Any] {
        guard let rawData = ThirdPartyImportService.nonEmpty(rawData) else {
            return [:]
        }

        for candidate in base64Candidates(from: rawData) {
            if let data = Data(base64Encoded: paddedBase64(candidate)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }

        throw NewAPIProviderImportError.invalidData
    }

    private static func base64Candidates(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let spaceFixed = trimmed.replacingOccurrences(of: " ", with: "+")
        let urlSafeFixed = spaceFixed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return [trimmed, spaceFixed, urlSafeFixed]
    }

    private static func paddedBase64(_ value: String) -> String {
        let remainder = value.count % 4
        guard remainder != 0 else {
            return value
        }
        return value + String(repeating: "=", count: 4 - remainder)
    }

    private static func firstNonEmptyValue(
        in payload: [String: Any],
        query: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = ThirdPartyImportService.nonEmpty(ThirdPartyImportService.string(payload[key])) {
                return value
            }
            if let value = ThirdPartyImportService.nonEmpty(query[key]) {
                return value
            }
        }
        return nil
    }
}
