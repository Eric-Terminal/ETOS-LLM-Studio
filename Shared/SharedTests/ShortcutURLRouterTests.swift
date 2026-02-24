// ============================================================================
// ShortcutURLRouterTests.swift
// ============================================================================
// ShortcutURLRouterTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import Shared

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
}
