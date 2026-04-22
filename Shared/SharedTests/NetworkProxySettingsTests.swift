import Foundation
import Testing
@testable import Shared

@Suite("NetworkProxySettings Tests")
struct NetworkProxySettingsTests {
    @Test("统一 URLSession 配置会等待网络恢复并抬高请求超时下限")
    func networkSessionConfigurationAppliesConnectivityDefaults() {
        let configuration = NetworkSessionConfiguration.makeConfiguration(
            from: .ephemeral,
            minimumRequestTimeout: 180
        )

        #expect(configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForRequest >= 180)
    }

#if os(iOS)
    @Test("iOS 统一 URLSession 配置启用 handover multipath")
    func networkSessionConfigurationEnablesHandoverMultipath() {
        let configuration = NetworkSessionConfiguration.makeConfiguration(from: .ephemeral)
        #expect(configuration.multipathServiceType == .handover)
    }
#endif

    @Test("提供商独立代理优先于全局代理")
    func providerOverrideTakesPrecedence() {
        let (defaults, suiteName) = makeDefaults()
        defer { clear(defaults, suiteName: suiteName) }

        NetworkProxySettings.saveGlobalConfiguration(
            NetworkProxyConfiguration(
                isEnabled: true,
                type: .http,
                host: "global.proxy.local",
                port: 7890
            ),
            defaults: defaults
        )

        let provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: ["k"],
            apiFormat: "openai-compatible",
            proxyConfiguration: NetworkProxyConfiguration(
                isEnabled: true,
                type: .socks5,
                host: "provider.proxy.local",
                port: 1080
            )
        )

        let resolved = NetworkProxySettings.resolvedConfiguration(for: provider, defaults: defaults)
        #expect(resolved?.host == "provider.proxy.local")
        #expect(resolved?.type == .socks5)
        #expect(resolved?.port == 1080)
    }

    @Test("提供商独立代理关闭时不回退全局代理")
    func disabledProviderOverrideBlocksGlobalProxy() {
        let (defaults, suiteName) = makeDefaults()
        defer { clear(defaults, suiteName: suiteName) }

        NetworkProxySettings.saveGlobalConfiguration(
            NetworkProxyConfiguration(
                isEnabled: true,
                type: .http,
                host: "global.proxy.local",
                port: 7890
            ),
            defaults: defaults
        )

        let provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: ["k"],
            apiFormat: "openai-compatible",
            proxyConfiguration: NetworkProxyConfiguration(
                isEnabled: false,
                type: .http,
                host: "provider.proxy.local",
                port: 8888
            )
        )

        let resolved = NetworkProxySettings.resolvedConfiguration(for: provider, defaults: defaults)
        #expect(resolved == nil)
    }

    @Test("无独立代理时使用全局代理")
    func fallbackToGlobalProxyWhenProviderHasNoOverride() {
        let (defaults, suiteName) = makeDefaults()
        defer { clear(defaults, suiteName: suiteName) }

        NetworkProxySettings.saveGlobalConfiguration(
            NetworkProxyConfiguration(
                isEnabled: true,
                type: .http,
                host: "global.proxy.local",
                port: 7890
            ),
            defaults: defaults
        )

        let provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: ["k"],
            apiFormat: "openai-compatible"
        )

        let resolved = NetworkProxySettings.resolvedConfiguration(for: provider, defaults: defaults)
        #expect(resolved?.host == "global.proxy.local")
        #expect(resolved?.port == 7890)
    }

    @Test("HTTP 代理鉴权会附加 Proxy-Authorization 请求头")
    func applyProxyAuthorizationHeaderForHTTPProxy() {
        var request = URLRequest(url: URL(string: "https://example.com/v1/chat")!)
        request.httpMethod = "POST"

        let configured = NetworkProxySettings.applyProxyAuthorizationHeader(
            to: request,
            configuration: NetworkProxyConfiguration(
                isEnabled: true,
                type: .http,
                host: "proxy.local",
                port: 8080,
                username: "alice",
                password: "secret"
            )
        )

        let expectedToken = Data("alice:secret".utf8).base64EncodedString()
        #expect(configured.value(forHTTPHeaderField: "Proxy-Authorization") == "Basic \(expectedToken)")
    }

    @Test("SOCKS5 代理字典包含地址、端口与鉴权")
    func makeSOCKSProxyDictionary() {
        let configuration = NetworkProxyConfiguration(
            isEnabled: true,
            type: .socks5,
            host: "socks.local",
            port: 1080,
            username: "bob",
            password: "pwd"
        )
        let dictionary = NetworkProxySettings.makeConnectionProxyDictionary(from: configuration)
        #expect(dictionary != nil)
        #expect(dictionary?.values.contains(where: { ($0 as? String) == "socks.local" }) == true)
        #expect(dictionary?.values.contains(where: { ($0 as? Int) == 1080 }) == true)
        #expect(dictionary?.values.contains(where: { ($0 as? String) == "bob" }) == true)
        #expect(dictionary?.values.contains(where: { ($0 as? String) == "pwd" }) == true)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "NetworkProxySettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建测试 UserDefaults。")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func clear(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
