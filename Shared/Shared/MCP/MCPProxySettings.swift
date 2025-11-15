// ============================================================================
// MCPProxySettings.swift
// ============================================================================
// 描述客户端侧的 MCP 代理配置，用于满足 ATS 要求。
// ============================================================================

import Foundation

public struct MCPProxySettings: Codable, Equatable {
    public var isEnabled: Bool
    public var baseURLString: String

    public init(isEnabled: Bool = true, baseURLString: String = MCPProxySettings.defaultBaseURLString) {
        self.isEnabled = isEnabled
        self.baseURLString = baseURLString
    }

    public static let defaultBaseURLString = "https://mcp.ericterminal.com"

    public var baseURL: URL? {
        URL(string: baseURLString)
    }

    public var isValid: Bool {
        isEnabled && baseURL != nil
    }

    public func proxiedURL(for target: URL) -> URL? {
        guard isValid, var components = URLComponents(url: baseURL!, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "url", value: target.absoluteString))
        components.queryItems = queryItems
        return components.url
    }
}
