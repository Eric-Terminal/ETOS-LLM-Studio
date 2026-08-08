// ============================================================================
// BrowserAgentFeatureView.swift
// ============================================================================
// ETOS LLM Studio
//
// 浏览器入口直接承载当前会话的 WKWebView。用户打开页面即接管同一标签页，
// Agent 暂停输入；离开页面后再把控制权交还。设置只保留为独立二级页面。
// ============================================================================

import ETOSCore
import SwiftUI
import Combine
import WebKit

struct BrowserAgentFeatureView: View {
    let sessionID: UUID?

    @ObservedObject private var manager = BrowserSessionManager.shared
    @State private var address = ""
    @State private var persistentProfileEnabled = false
    @State private var isWorking = false
    @State private var isShowingSettings = false
    @State private var errorMessage: String?
    @State private var tabs: [BrowserAgentTabSummary] = []
    @State private var selectedTabID: UUID?
    @State private var selectedWebView: WKWebView?
    @FocusState private var addressFocused: Bool

    var body: some View {
        Group {
            if sessionID == nil {
                ContentUnavailableView(
                    NSLocalizedString("请先打开一个聊天会话。", comment: "Browser Agent requires chat session"),
                    systemImage: "safari"
                )
            } else {
                VStack(spacing: 0) {
                    tabBar
                    addressBar
                    browserContent
                    browserToolbar
                }
            }
        }
        .navigationTitle(NSLocalizedString("浏览器", comment: "Browser Agent browser title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    openBlankTab()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(NSLocalizedString("新建标签页", comment: "Browser Agent new tab accessibility label"))
                .disabled(sessionID == nil || isWorking)

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(NSLocalizedString("浏览器设置", comment: "Browser Agent settings accessibility label"))
                .disabled(sessionID == nil)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                BrowserAgentSettingsView(
                    persistentProfileEnabled: $persistentProfileEnabled,
                    sessionID: sessionID
                )
            }
        }
        .task(id: sessionID) {
            await prepareSession()
        }
        .onReceive(manager.objectWillChange) { _ in
            guard !addressFocused else { return }
            Task { @MainActor in
                await Task.yield()
                refreshBrowserState()
            }
        }
        .onDisappear {
            if let sessionID {
                manager.setUserControlling(false, sessionID: sessionID)
            }
        }
        .alert(
            NSLocalizedString("浏览器操作失败", comment: "Browser Agent operation failed alert"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "Dismiss alert"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(tabs) { tab in
                    let isSelected = tab.id == selectedTabID
                    HStack(spacing: 4) {
                        Button {
                            select(tab.id)
                        } label: {
                            Text(tab.title)
                                .font(.caption)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .lineLimit(1)
                                .frame(maxWidth: 140)
                        }
                        .buttonStyle(.plain)

                        Button {
                            close(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("关闭标签页", comment: "Browser Agent close tab accessibility label"))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1))
                    .clipShape(.capsule)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var addressBar: some View {
        HStack {
            if selectedWebView?.isLoading == true {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: selectedWebView?.url?.scheme == "https" ? "lock.fill" : "globe")
                    .foregroundStyle(.secondary)
            }

            TextField(NSLocalizedString("搜索或输入网页地址", comment: "Browser Agent address field"), text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit(openAddress)

            if selectedWebView?.isLoading == true {
                Button {
                    selectedWebView?.stopLoading()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(NSLocalizedString("停止载入", comment: "Browser Agent stop loading"))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private var browserContent: some View {
        if let webView = selectedWebView, let selectedTabID {
            BrowserAgentWebView(webView: webView)
                .id(selectedTabID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isWorking {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                NSLocalizedString("没有打开的标签页", comment: "Browser Agent no open tabs"),
                systemImage: "safari"
            )
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 0) {
            browserToolbarButton(
                NSLocalizedString("后退", comment: "Browser Agent back"),
                systemImage: "chevron.left",
                disabled: selectedWebView?.canGoBack != true
            ) {
                selectedWebView?.goBack()
            }
            browserToolbarButton(
                NSLocalizedString("前进", comment: "Browser Agent forward"),
                systemImage: "chevron.right",
                disabled: selectedWebView?.canGoForward != true
            ) {
                selectedWebView?.goForward()
            }
            browserToolbarButton(
                NSLocalizedString("重新载入", comment: "Browser Agent reload"),
                systemImage: "arrow.clockwise",
                disabled: selectedWebView == nil
            ) {
                selectedWebView?.reload()
            }
            browserToolbarButton(
                NSLocalizedString("新建标签页", comment: "Browser Agent new tab"),
                systemImage: "plus.square.on.square",
                disabled: isWorking
            ) {
                openBlankTab()
            }
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func browserToolbarButton(
        _ accessibilityLabel: String,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity)
        }
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func prepareSession() async {
        guard let sessionID else { return }
        persistentProfileEnabled = await Task.detached(priority: .utility) {
            Persistence.browserAgentDataProfile(sessionID: sessionID) == .persistentShared
        }.value
        manager.setUserControlling(true, sessionID: sessionID)
        if manager.tabs(sessionID: sessionID).isEmpty {
            do {
                _ = try await manager.openTab(sessionID: sessionID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refreshBrowserState()
    }

    private func openAddress() {
        guard let sessionID else { return }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let url = resolvedAddress(text) else {
            errorMessage = NSLocalizedString("网页地址无效。", comment: "Browser Agent invalid address")
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                if let selectedTabID {
                    _ = try await manager.navigate(sessionID: sessionID, tabID: selectedTabID, url: url)
                } else {
                    _ = try await manager.openTab(sessionID: sessionID, url: url)
                }
                refreshBrowserState()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openBlankTab() {
        guard let sessionID else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await manager.openTab(sessionID: sessionID)
                address = ""
                addressFocused = true
                refreshBrowserState()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func select(_ tabID: UUID) {
        guard let sessionID else { return }
        do {
            try manager.selectTab(sessionID: sessionID, tabID: tabID)
            refreshBrowserState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func close(_ tabID: UUID) {
        guard let sessionID else { return }
        do {
            _ = try manager.closeTab(sessionID: sessionID, tabID: tabID)
            refreshBrowserState()
            if manager.tabs(sessionID: sessionID).isEmpty {
                openBlankTab()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAddress() {
        guard let sessionID else {
            address = ""
            return
        }
        do {
            address = try manager.currentURL(sessionID: sessionID, tabID: selectedTabID)?.absoluteString ?? ""
        } catch {
            address = ""
        }
    }

    private func refreshBrowserState() {
        guard let sessionID else {
            tabs = []
            selectedTabID = nil
            selectedWebView = nil
            address = ""
            return
        }
        tabs = manager.tabs(sessionID: sessionID)
        selectedTabID = manager.selectedTabID(sessionID: sessionID)
        selectedWebView = manager.selectedWebView(sessionID: sessionID)
        guard !addressFocused else { return }
        refreshAddress()
    }

    private func resolvedAddress(_ text: String) -> URL? {
        if text.contains("://") {
            return URL(string: text)
        }
        if !text.contains(where: \.isWhitespace), text.contains(".") {
            return URL(string: "https://\(text)")
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }
}

private struct BrowserAgentSettingsView: View {
    @Binding var persistentProfileEnabled: Bool
    let sessionID: UUID?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle(
                    NSLocalizedString("保留网站登录状态", comment: "Browser Agent persistent profile toggle"),
                    isOn: $persistentProfileEnabled
                )
                .onChange(of: persistentProfileEnabled) { _, newValue in
                    guard let sessionID else { return }
                    let profile: BrowserAgentDataProfile = newValue ? .persistentShared : .sessionIsolated
                    Task.detached(priority: .utility) {
                        _ = Persistence.saveBrowserAgentDataProfile(profile, sessionID: sessionID)
                    }
                }
            } footer: {
                Text(NSLocalizedString("关闭时，新标签页使用当前会话的临时网站数据；切换只影响之后创建的标签页和新的 Agent Run。", comment: "Browser Agent profile footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("浏览器设置", comment: "Browser Agent settings title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "Done")) {
                    dismiss()
                }
            }
        }
    }
}

private struct BrowserAgentWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
