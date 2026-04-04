import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif
import Combine

public enum NetworkProxySettings {
    private enum Keys {
        static let isEnabled = "networkProxy.global.isEnabled"
        static let type = "networkProxy.global.type"
        static let host = "networkProxy.global.host"
        static let port = "networkProxy.global.port"
        static let username = "networkProxy.global.username"
        static let password = "networkProxy.global.password"
    }

    public static func loadGlobalConfiguration(defaults: UserDefaults = .standard) -> NetworkProxyConfiguration {
        let storedType = defaults.string(forKey: Keys.type) ?? NetworkProxyType.http.rawValue
        let type = NetworkProxyType(rawValue: storedType) ?? .http
        let storedPort = defaults.object(forKey: Keys.port) as? Int ?? 8080
        let validPort = (1...65535).contains(storedPort) ? storedPort : 8080
        return NetworkProxyConfiguration(
            isEnabled: defaults.object(forKey: Keys.isEnabled) as? Bool ?? false,
            type: type,
            host: defaults.string(forKey: Keys.host) ?? "",
            port: validPort,
            username: defaults.string(forKey: Keys.username) ?? "",
            password: defaults.string(forKey: Keys.password) ?? ""
        )
    }

    public static func saveGlobalConfiguration(
        _ configuration: NetworkProxyConfiguration,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(configuration.isEnabled, forKey: Keys.isEnabled)
        defaults.set(configuration.type.rawValue, forKey: Keys.type)
        defaults.set(configuration.host, forKey: Keys.host)
        defaults.set(configuration.port, forKey: Keys.port)
        defaults.set(configuration.username, forKey: Keys.username)
        defaults.set(configuration.password, forKey: Keys.password)
    }

    /// 解析最终代理配置：提供商独立配置优先；无独立配置时回退到全局配置。
    public static func resolvedConfiguration(
        for provider: Provider?,
        defaults: UserDefaults = .standard
    ) -> NetworkProxyConfiguration? {
        if let override = provider?.proxyConfiguration {
            return override.normalizedIfEnabled
        }
        return loadGlobalConfiguration(defaults: defaults).normalizedIfEnabled
    }

    public static func makeConnectionProxyDictionary(
        from configuration: NetworkProxyConfiguration
    ) -> [AnyHashable: Any]? {
        guard let effective = configuration.normalizedIfEnabled else { return nil }
#if canImport(CFNetwork)
        var dictionary: [AnyHashable: Any] = [:]
        switch effective.type {
        case .http:
            dictionary[kCFNetworkProxiesHTTPEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPProxy as String] = effective.host
            dictionary[kCFNetworkProxiesHTTPPort as String] = effective.port
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = effective.host
            dictionary[kCFNetworkProxiesHTTPSPort as String] = effective.port
        case .socks5:
            dictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
            dictionary[kCFNetworkProxiesSOCKSProxy as String] = effective.host
            dictionary[kCFNetworkProxiesSOCKSPort as String] = effective.port
            dictionary[kCFStreamPropertySOCKSProxyHost as String] = effective.host
            dictionary[kCFStreamPropertySOCKSProxyPort as String] = effective.port
            dictionary[kCFStreamPropertySOCKSVersion as String] = kCFStreamSocketSOCKSVersion5 as String
        }

        if effective.hasAuthentication {
            dictionary[kCFProxyUsernameKey as String] = effective.trimmedUsername
            dictionary[kCFProxyPasswordKey as String] = effective.trimmedPassword
            dictionary[kCFStreamPropertySOCKSUser as String] = effective.trimmedUsername
            dictionary[kCFStreamPropertySOCKSPassword as String] = effective.trimmedPassword
        }

        return dictionary
#else
        return nil
#endif
    }

    /// HTTP 代理鉴权头。仅在 HTTP 代理且填写用户名时注入。
    public static func applyProxyAuthorizationHeader(
        to request: URLRequest,
        configuration: NetworkProxyConfiguration?
    ) -> URLRequest {
        guard let configuration = configuration?.normalizedIfEnabled,
              configuration.type == .http,
              configuration.hasAuthentication else {
            return request
        }

        let credential = "\(configuration.trimmedUsername):\(configuration.trimmedPassword)"
        guard let data = credential.data(using: .utf8), !data.isEmpty else {
            return request
        }

        var updatedRequest = request
        updatedRequest.setValue(
            "Basic \(data.base64EncodedString())",
            forHTTPHeaderField: "Proxy-Authorization"
        )
        return updatedRequest
    }
}

@MainActor
public final class NetworkProxySettingsStore: ObservableObject {
    public static let shared = NetworkProxySettingsStore()

    private let defaults: UserDefaults

    @Published public var isEnabled: Bool {
        didSet { persist() }
    }

    @Published public var type: NetworkProxyType {
        didSet { persist() }
    }

    @Published public var host: String {
        didSet { persist() }
    }

    @Published public var port: Int {
        didSet {
            let clamped = Swift.max(1, Swift.min(65535, port))
            if clamped != port {
                port = clamped
                return
            }
            persist()
        }
    }

    @Published public var username: String {
        didSet { persist() }
    }

    @Published public var password: String {
        didSet { persist() }
    }

    public var snapshot: NetworkProxyConfiguration {
        NetworkProxyConfiguration(
            isEnabled: isEnabled,
            type: type,
            host: host,
            port: port,
            username: username,
            password: password
        )
    }

    public func update(with configuration: NetworkProxyConfiguration) {
        isEnabled = configuration.isEnabled
        type = configuration.type
        host = configuration.host
        port = configuration.port
        username = configuration.username
        password = configuration.password
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let config = NetworkProxySettings.loadGlobalConfiguration(defaults: defaults)
        isEnabled = config.isEnabled
        type = config.type
        host = config.host
        port = config.port
        username = config.username
        password = config.password
    }

    private func persist() {
        NetworkProxySettings.saveGlobalConfiguration(snapshot, defaults: defaults)
    }
}
