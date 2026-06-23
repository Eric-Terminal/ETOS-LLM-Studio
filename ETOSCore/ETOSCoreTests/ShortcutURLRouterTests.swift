// ============================================================================
// ShortcutURLRouterTests.swift
// ============================================================================
// ShortcutURLRouterTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("ShortcutURLRouter Tests")
struct ShortcutURLRouterTests {

    @MainActor
    @Test("callback route is recognized")
    func testCallbackRoute() async {
        let url = URL(string: "etosllmstudio://shortcuts/callback?request_id=dummy&status=success")!
        let handled = await ShortcutURLRouter.shared.handleIncomingURL(url)
        #expect(handled == true)
    }

    @MainActor
    @Test("single-slash callback route is recognized")
    func testSingleSlashCallbackRoute() async {
        let url = URL(string: "etosllmstudio:/shortcuts/callback?request_id=dummy&status=success")!
        let handled = await ShortcutURLRouter.shared.handleIncomingURL(url)
        #expect(handled == true)
    }

    @MainActor
    @Test("unknown scheme is ignored")
    func testUnknownSchemeIgnored() async {
        let url = URL(string: "https://example.com/shortcuts/callback")!
        let handled = await ShortcutURLRouter.shared.handleIncomingURL(url)
        #expect(handled == false)
    }

    @MainActor
    @Test("template status route is recognized")
    func testTemplateStatusRoute() async {
        let url = URL(string: "etosllmstudio://shortcuts/template-status?status=error&stage=run")!
        let handled = await ShortcutURLRouter.shared.handleIncomingURL(url)
        #expect(handled == true)
    }

    @MainActor
    @Test("legacy host import route is recognized")
    func testLegacyHostImportRoute() async {
        let url = URL(string: "etosllmstudio://shortcut/import?source=clipboard")!
        let handled = await ShortcutURLRouter.shared.handleIncomingURL(url)
        #expect(handled == true)
    }

    @Test("New API provider deeplink is parsed")
    func testNewAPIProviderDeeplinkParse() throws {
        let payload = #"{"id":"new-api","baseUrl":"https://api.ericterminal.com","apiKey":"sk-test"}"#
        var components = URLComponents()
        components.scheme = ShortcutURLRouter.appScheme
        components.host = "provider"
        components.path = "/install"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "data", value: Data(payload.utf8).base64EncodedString())
        ]
        let url = try #require(components.url)

        #expect(NewAPIProviderImportURLHandler.canHandle(url))
        let provider = try NewAPIProviderImportURLHandler.parseProvider(from: url)

        #expect(provider.name == "New API")
        #expect(provider.baseURL == "https://api.ericterminal.com/v1")
        #expect(provider.apiKeys == ["sk-test"])
        #expect(provider.apiFormat == "openai-compatible")
    }
}
