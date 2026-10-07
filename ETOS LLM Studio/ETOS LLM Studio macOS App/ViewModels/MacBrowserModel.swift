import AppKit
import Combine
import ETOSCore
import Foundation
import WebKit

@MainActor
final class MacBrowserModel: ObservableObject {
    @Published private(set) var sessionID: UUID?
    @Published private(set) var lease = UUID()
    @Published private(set) var epoch = UUID()
    @Published private(set) var tabs: [BrowserAgentTabSummary] = []
    @Published private(set) var selectedTabID: UUID?
    @Published private(set) var webView: WKWebView?
    @Published private(set) var control = BrowserAgentControlState.idle
    @Published private(set) var profile = BrowserAgentDataProfile.sessionIsolated
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSuspended = false
    @Published private(set) var canPersistProfile = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentAddress = ""
    @Published private(set) var viewport: CGSize?
    @Published var error: String?

    private let manager = BrowserSessionManager.shared
    private var subscription: AnyCancellable?
    private var observations: [NSKeyValueObservation] = []
    private var preparing: Task<Void, Never>?
    private var navigation: Task<Void, Never>?
    private var profileWrite: Task<Void, Error>?
    private var lifecycle: Task<Void, Never>?
    private var navigationID = UUID()

    var canControl: Bool { isLoaded && !isSuspended && !isWorking && control.controller == .user && AppLockManager.shared.state != .locked }
    var canEditProfile: Bool { canPersistProfile && isLoaded && !isSuspended && !isSaving && AppLockManager.shared.state != .locked }

    init() {
        subscription = manager.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func open(sessionID: UUID, persisted: Bool, lease: UUID) {
        guard !isSuspended else { return }
        let previousPreparation = preparing
        leave(lease: self.lease)
        self.sessionID = sessionID; self.lease = lease; canPersistProfile = persisted
        isLoaded = false; error = nil
        let epoch = epoch
        let previousNavigation = navigation
        preparing = Task { [weak self] in
            await previousNavigation?.value
            await previousPreparation?.value
            guard !Task.isCancelled else { return }
            let profile = await Task.detached(priority: .utility) {
                persisted ? Persistence.browserAgentDataProfile(sessionID: sessionID) : .sessionIsolated
            }.value
            guard let self, !Task.isCancelled, self.lease == lease, self.epoch == epoch, !isSuspended else { return }
            self.profile = profile
            let controller = manager.controlState(sessionID: sessionID).controller
            if controller == .idle || controller == .user { manager.beginUserTakeover(sessionID: sessionID) }
            do {
                if manager.tabs(sessionID: sessionID).isEmpty, manager.isUserControlling(sessionID: sessionID) {
                    _ = try await manager.openTab(sessionID: sessionID, dataProfile: profile)
                }
                guard !Task.isCancelled, self.lease == lease, self.epoch == epoch else { return }
                isLoaded = true; refresh()
            } catch is CancellationError { }
            catch { if self.lease == lease { self.error = error.localizedDescription } }
        }
    }

    func leave(lease: UUID) {
        guard self.lease == lease else { return }
        preparing?.cancel(); stop()
        if let sessionID, manager.isUserControlling(sessionID: sessionID) { manager.setUserControlling(false, sessionID: sessionID) }
        observations.removeAll(); webView = nil; sessionID = nil; tabs = []; selectedTabID = nil; isLoaded = false
    }

    func takeOver() {
        guard !isSuspended, let sessionID else { return }
        manager.beginUserTakeover(sessionID: sessionID); refresh()
    }

    func release() {
        guard !isSuspended, let sessionID else { return }
        webView?.window?.makeFirstResponder(nil)
        stop(); manager.setUserControlling(false, sessionID: sessionID)
    }

    func select(_ id: UUID) {
        guard canControl, let sessionID else { return }
        do { try manager.selectTab(sessionID: sessionID, tabID: id); refresh() }
        catch { self.error = error.localizedDescription }
    }

    func close(_ id: UUID) {
        guard canControl, let sessionID else { return }
        do { _ = try manager.closeTab(sessionID: sessionID, tabID: id); refresh() }
        catch { self.error = error.localizedDescription }
    }

    func navigate(_ address: String? = nil) {
        guard canControl, let sessionID else { return }
        let lease = lease, epoch = epoch, selected = selectedTabID, profile = profile
        isWorking = true; error = nil; navigationID = UUID()
        let operation = navigationID
        navigation = Task { [weak self] in
            guard let self else { return }
            defer { if navigationID == operation { isWorking = false; refresh() } }
            do {
                let url = try await Task.detached(priority: .utility) { try address.map(MacBrowserAddress.resolve) }.value
                try Task.checkCancellation()
                guard self.lease == lease, self.epoch == epoch, !isSuspended else { return }
                if let url, let selected { _ = try await manager.navigate(sessionID: sessionID, tabID: selected, url: url) }
                else { _ = try await manager.openTab(sessionID: sessionID, url: url, dataProfile: profile) }
            } catch is CancellationError { }
            catch { if self.lease == lease, self.epoch == epoch { self.error = error.localizedDescription } }
        }
    }

    func stop() { navigation?.cancel(); webView?.stopLoading() }
    func back() { if canControl { webView?.goBack() } }
    func forward() { if canControl { webView?.goForward() } }
    func reload() { if canControl { webView?.reload() } }

    func saveProfile(_ value: BrowserAgentDataProfile, expected: BrowserAgentDataProfile, expectedLease: UUID) async throws {
        guard canEditProfile, lease == expectedLease, profile == expected, let sessionID else { throw BrowserSessionPreferencesError.changed }
        isSaving = true
        let task = Task.detached(priority: .utility) { try Persistence.saveBrowserProfileDraft(value, expected: expected, sessionID: sessionID) }
        profileWrite = task
        defer { isSaving = false; profileWrite = nil }
        try await task.value
        if lease == expectedLease { profile = value }
    }

    func suspend() {
        isSuspended = true; epoch = UUID(); preparing?.cancel(); stop()
        manager.suspendInteraction(); observations.removeAll(); webView = nil
        let previous = lifecycle
        lifecycle = Task { await previous?.value; await BrowserAgentToolExecutor.shared.suspendAndWait() }
    }

    func resume() {
        guard isSuspended else { return }
        let previous = lifecycle, token = epoch
        lifecycle = Task { [weak self] in
            await previous?.value
            guard let self, epoch == token, AppLockManager.shared.state != .locked else { return }
            await BrowserAgentToolExecutor.shared.resumeAfterDataOperation()
            guard epoch == token, AppLockManager.shared.state != .locked else { return }
            manager.resumeInteraction(); isSuspended = false
        }
    }

    func discardRestoredSessions() { manager.discardAllSessions(); sessionID = nil; tabs = []; selectedTabID = nil; isLoaded = false }

    func waitForPendingOperations() async {
        await lifecycle?.value; await preparing?.value; await navigation?.value
        _ = try? await profileWrite?.value
    }

    private func refresh() {
        guard !isSuspended, let sessionID else { return }
        tabs = manager.tabs(sessionID: sessionID); selectedTabID = manager.selectedTabID(sessionID: sessionID)
        control = manager.controlState(sessionID: sessionID)
        if let tab = tabs.first(where: { $0.id == selectedTabID }), let width = tab.viewportWidth, let height = tab.viewportHeight {
            viewport = CGSize(width: width, height: height)
        } else { viewport = nil }
        let selected = manager.selectedWebView(sessionID: sessionID)
        if selected !== webView {
            observations.removeAll(); webView = selected
            if let selected {
                observations = [
                    selected.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } },
                    selected.observe(\.url) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } },
                    selected.observe(\.title) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } },
                    selected.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } },
                    selected.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } }
                ]
            }
        }
        canGoBack = selected?.canGoBack == true; canGoForward = selected?.canGoForward == true
        isLoading = selected?.isLoading == true; currentAddress = selected?.url?.absoluteString ?? ""
    }
}

enum MacBrowserAddress {
    static func resolve(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BrowserAgentError.invalidArguments(NSLocalizedString("网页地址无效。", comment: "")) }
        if text.contains("://") {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
                throw BrowserAgentError.invalidArguments(NSLocalizedString("浏览器仅接受 http 或 https URL。", comment: ""))
            }
            return url
        }
        if !text.contains(where: \.isWhitespace), text.contains("."), let url = URL(string: "https://\(text)"), url.host != nil { return url }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url!
    }
}
