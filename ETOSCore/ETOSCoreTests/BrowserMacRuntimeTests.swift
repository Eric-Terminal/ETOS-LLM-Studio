import Foundation
import Testing
@testable import ETOSCore

#if os(macOS) && canImport(WebKit)
import WebKit

@MainActor
struct BrowserMacRuntimeTests {
    @Test("Mac 使用本机浏览器能力和桌面视口，移动标识可重置")
    func nativeCapabilities() {
        let manager = BrowserSessionManager()
        let capabilities = manager.capabilities()
        #expect(capabilities.platform == "macOS")
        #expect(capabilities.supportsScreenshot && capabilities.supportsDownload && capabilities.supportsUserTakeover)
        #expect(!capabilities.supportsIPhoneDelegation)
        #expect(BrowserWebPlatform.defaultViewport.width == 1024)
        #expect(BrowserWebPlatform.userAgent(for: .mobileSafari)?.contains("iPhone") == true)
        #expect(BrowserWebPlatform.userAgent(for: .desktopSafari) == nil && BrowserWebPlatform.userAgent(for: .reset) == nil)
    }

    @Test("同会话标签页共享临时网站数据，不同会话隔离，持久化数据需显式选择")
    func websiteDataIsolation() async throws {
        let manager = BrowserSessionManager(), first = UUID(), second = UUID()
        defer { manager.discardAllSessions() }
        let a = try await manager.openTab(sessionID: first, dataProfile: .sessionIsolated)
        let b = try await manager.openTab(sessionID: first, dataProfile: .sessionIsolated)
        let c = try await manager.openTab(sessionID: second, dataProfile: .sessionIsolated)
        let d = try await manager.openTab(sessionID: second, dataProfile: .persistentShared)
        let storeA = try manager.webView(sessionID: first, tabID: a.id).configuration.websiteDataStore
        let storeB = try manager.webView(sessionID: first, tabID: b.id).configuration.websiteDataStore
        let storeC = try manager.webView(sessionID: second, tabID: c.id).configuration.websiteDataStore
        let storeD = try manager.webView(sessionID: second, tabID: d.id).configuration.websiteDataStore
        #expect(storeA === storeB && storeA !== storeC)
        #expect(!storeA.isPersistent && storeD.isPersistent)
        _ = try manager.closeTab(sessionID: first, tabID: a.id)
        #expect(manager.tabs(sessionID: first).map(\.id) == [b.id])
        #expect(manager.tabs(sessionID: second).count == 2)
    }

    @Test("暂停拒绝新标签页和旧标签访问，恢复数据库清除运行期页面")
    func suspensionAndRestoreInvalidateTabs() async throws {
        let manager = BrowserSessionManager(), session = UUID()
        let tab = try await manager.openTab(sessionID: session, dataProfile: .sessionIsolated)
        manager.suspendInteraction()
        await #expect(throws: CancellationError.self) { try await manager.openTab(sessionID: session, dataProfile: .sessionIsolated) }
        #expect(throws: CancellationError.self) { try manager.webView(sessionID: session, tabID: tab.id) }
        manager.discardAllSessions(); manager.resumeInteraction()
        #expect(manager.tabs(sessionID: session).isEmpty)
        #expect(throws: BrowserAgentError.self) { try manager.webView(sessionID: session, tabID: tab.id) }
        let reopened = try await manager.openTab(sessionID: session, dataProfile: .sessionIsolated)
        #expect(reopened.id != tab.id)
        manager.discardAllSessions()
    }
}
#endif
