// ============================================================================
// BrowserSessionManagerUnavailable.swift
// ============================================================================
// ETOS LLM Studio
//
// 没有 UIKit WebKit、且不是 watchOS 运行时探测路径的平台使用明确失败实现。
// ============================================================================

import Combine
import Foundation

#if !os(watchOS) && !(canImport(WebKit) && canImport(UIKit))

@MainActor
public final class BrowserSessionManager: ObservableObject {
    public static let shared = BrowserSessionManager()

    public func capabilities() -> BrowserAgentCapabilities {
        BrowserAgentCapabilities(
            platform: "unsupported",
            isExperimental: true,
            supportsNavigation: false,
            supportsSnapshot: false,
            supportsClick: false,
            supportsTyping: false,
            supportsScrolling: false,
            supportsJavaScript: false,
            supportsScreenshot: false,
            supportsDownload: false,
            supportsUserTakeover: false,
            supportsIPhoneDelegation: false,
            notes: [NSLocalizedString("当前平台没有可用的浏览器运行时。", comment: "Browser Agent unavailable platform")]
        )
    }

    public func tabs(sessionID: UUID) -> [BrowserAgentTabSummary] { [] }
    public func isUserControlling(sessionID: UUID) -> Bool { false }
    public func setUserControlling(_ isControlling: Bool, sessionID: UUID) {}
    public func beginUserTakeover(sessionID: UUID) {}
    public func controlState(sessionID: UUID) -> BrowserAgentControlState { .idle }
    public func beginAgentAction(sessionID: UUID, tabID: UUID?, action: BrowserAgentAction) {}
    public func finishAgentAction(
        sessionID: UUID,
        action: BrowserAgentAction,
        status: BrowserAgentControlStatus,
        detail: String?
    ) {}

    public func openTab(
        sessionID: UUID,
        url: URL? = nil,
        dataProfile: BrowserAgentDataProfile? = nil,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> BrowserAgentTabSummary {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func closeTab(sessionID: UUID, tabID: UUID?) throws -> BrowserAgentTabSummary {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func navigate(
        sessionID: UUID,
        tabID: UUID?,
        url: URL,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> BrowserAgentTabSummary {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func snapshot(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentSnapshot {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func click(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func type(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        text: String,
        submit: Bool,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func scroll(sessionID: UUID, tabID: UUID?, deltaX: Double, deltaY: Double, allowedAgentNavigationHosts: Set<String>? = nil) async throws {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func evaluateJavaScript(
        sessionID: UUID,
        tabID: UUID?,
        script: String,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> JSONValue {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func currentURL(sessionID: UUID, tabID: UUID?) throws -> URL? {
        throw BrowserAgentError.unsupported("WKWebView")
    }

    public func interactionDestination(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        submittingForm: Bool
    ) async throws -> URL? {
        throw BrowserAgentError.unsupported("WKWebView")
    }
}

#endif
