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
import UIKit

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
    @State private var controlState = BrowserAgentControlState.idle
    @State private var isUserTakingOver = false
    @State private var isViewActive = false
    @FocusState private var addressFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
                        .disabled(!canInteract)
                    addressBar
                        .disabled(!canInteract)
                    browserContent
                    browserToolbar
                        .disabled(!canInteract)
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
                .disabled(sessionID == nil || isWorking || !canInteract)

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(NSLocalizedString("浏览器设置", comment: "Browser Agent settings accessibility label"))
                .disabled(sessionID == nil)
            }
        }
        .navigationDestination(isPresented: $isShowingSettings) {
            BrowserAgentSettingsView(
                persistentProfileEnabled: $persistentProfileEnabled,
                sessionID: sessionID
            )
        }
        .guideSettingsPageContext(
            id: "settings-browser-agent",
            title: NSLocalizedString("Browser Agent", comment: "Browser Agent guide title"),
            documents: [GuideDocumentReference(id: "browser-agent", title: "Browser Agent")],
            settings: [
                .bool("persistent_profile_enabled", label: NSLocalizedString("保留网站登录状态", comment: "向导设置字段"), get: { persistentProfileEnabled }, set: { persistentProfileEnabled = $0 }),
                .readOnly("session_available", label: NSLocalizedString("聊天会话可用", comment: "向导设置字段"), value: { .bool(sessionID != nil) }),
                .readOnly("control_state", label: NSLocalizedString("浏览器控制状态", comment: "向导设置字段"), value: { .string(controlState.controller.rawValue) }),
                .readOnly("selected_tab_id", label: NSLocalizedString("当前标签页", comment: "向导设置字段"), value: { .string(selectedTabID?.uuidString ?? "") }),
                .readOnly("tabs", label: NSLocalizedString("标签页", comment: "向导设置字段"), value: {
                    .array(tabs.map { tab in
                        .dictionary([
                            "id": .string(tab.id.uuidString),
                            "title": .string(tab.title),
                            "url": .string(tab.url ?? ""),
                            "loading": .bool(tab.isLoading)
                        ])
                    })
                })
            ]
        )
        .task(id: sessionID) {
            await prepareSession()
        }
        .onAppear { isViewActive = true }
        .onReceive(manager.objectWillChange) { _ in
            guard !addressFocused else { return }
            Task { @MainActor in
                await Task.yield()
                refreshBrowserState()
            }
        }
        .onDisappear {
            isViewActive = false
            if let sessionID, isUserTakingOver {
                isUserTakingOver = false
                manager.setUserControlling(false, sessionID: sessionID)
            }
        }
        .onChange(of: controlState) { _, newValue in
            announceControlState(newValue)
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
        ZStack(alignment: .bottom) {
            Group {
                if let webView = selectedWebView, let selectedTabID {
                    BrowserAgentWebView(webView: webView)
                        .id(selectedTabID)
                        .allowsHitTesting(canInteract)
                } else if isWorking {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        NSLocalizedString("没有打开的标签页", comment: "Browser Agent no open tabs"),
                        systemImage: "safari"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsAgentOverlay {
                agentStatusOverlay
                    .padding()
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .linear(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.82),
            value: showsAgentOverlay
        )
    }

    private var agentStatusOverlay: some View {
        HStack {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading) {
                Text(controlStatusTitle)
                    .font(.subheadline.weight(.semibold))
                if let domain = controlState.domain, !domain.isEmpty {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if controlState.controller == .agent {
                Button(NSLocalizedString("接管", comment: "Browser Agent take over button")) {
                    takeOverBrowser()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var canInteract: Bool {
        isUserTakingOver && controlState.controller == .user
    }

    private var showsAgentOverlay: Bool {
        controlState.controller == .agent || controlState.controller == .returningToAgent
    }

    private var controlStatusTitle: String {
        if controlState.controller == .returningToAgent {
            return NSLocalizedString("正在把页面交还给 Agent", comment: "Browser Agent returning control status")
        }
        guard let action = controlState.action else {
            return NSLocalizedString("Agent 正在操作网页", comment: "Browser Agent generic running status")
        }
        return String(
            format: NSLocalizedString("Agent 正在%@", comment: "Browser Agent action running status"),
            actionDisplayName(action)
        )
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
        let currentControl = manager.controlState(sessionID: sessionID)
        controlState = currentControl
        if currentControl.controller == .agent || currentControl.controller == .returningToAgent {
            isUserTakingOver = false
        } else {
            manager.beginUserTakeover(sessionID: sessionID)
            isUserTakingOver = true
            controlState = manager.controlState(sessionID: sessionID)
        }
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
            controlState = .idle
            isUserTakingOver = false
            return
        }
        tabs = manager.tabs(sessionID: sessionID)
        selectedTabID = manager.selectedTabID(sessionID: sessionID)
        selectedWebView = manager.selectedWebView(sessionID: sessionID)
        let latestControl = manager.controlState(sessionID: sessionID)
        controlState = latestControl
        if latestControl.controller == .user {
            isUserTakingOver = true
        } else if latestControl.controller == .agent || latestControl.controller == .returningToAgent {
            isUserTakingOver = false
        } else if isViewActive, !isUserTakingOver {
            takeOverBrowser()
        }
        guard !addressFocused else { return }
        refreshAddress()
    }

    private func takeOverBrowser() {
        guard let sessionID else { return }
        isUserTakingOver = true
        manager.beginUserTakeover(sessionID: sessionID)
        controlState = manager.controlState(sessionID: sessionID)
    }

    private func announceControlState(_ state: BrowserAgentControlState) {
        let announcement: String?
        if state.controller == .agent {
            announcement = controlStatusTitle
        } else {
            switch state.status {
            case .completed:
                announcement = NSLocalizedString("Agent 已完成浏览器操作", comment: "Browser Agent VoiceOver completed announcement")
            case .failed:
                announcement = NSLocalizedString("Agent 浏览器操作失败", comment: "Browser Agent VoiceOver failed announcement")
            case .interrupted:
                announcement = NSLocalizedString("Agent 浏览器操作已中断", comment: "Browser Agent VoiceOver interrupted announcement")
            case .idle, .running, .waiting:
                announcement = nil
            }
        }
        if let announcement {
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    private func actionDisplayName(_ action: BrowserAgentAction) -> String {
        switch action {
        case .capabilities: return NSLocalizedString("检查浏览器能力", comment: "Browser Agent action label")
        case .listTabs: return NSLocalizedString("读取标签页", comment: "Browser Agent action label")
        case .openTab: return NSLocalizedString("打开标签页", comment: "Browser Agent action label")
        case .navigate: return NSLocalizedString("载入网页", comment: "Browser Agent action label")
        case .snapshot: return NSLocalizedString("读取页面快照", comment: "Browser Agent action label")
        case .getText: return NSLocalizedString("读取页面文字", comment: "Browser Agent action label")
        case .getPageInfo: return NSLocalizedString("读取页面信息", comment: "Browser Agent action label")
        case .findElements: return NSLocalizedString("查找页面元素", comment: "Browser Agent action label")
        case .click: return NSLocalizedString("点击页面元素", comment: "Browser Agent action label")
        case .type: return NSLocalizedString("输入文字", comment: "Browser Agent action label")
        case .hover: return NSLocalizedString("悬停页面元素", comment: "Browser Agent action label")
        case .scroll: return NSLocalizedString("滚动页面", comment: "Browser Agent action label")
        case .scrollAndCollect: return NSLocalizedString("滚动并收集内容", comment: "Browser Agent action label")
        case .waitForDOMStable: return NSLocalizedString("等待页面稳定", comment: "Browser Agent action label")
        case .getReadable: return NSLocalizedString("提取页面正文", comment: "Browser Agent action label")
        case .getBackbone: return NSLocalizedString("读取页面结构", comment: "Browser Agent action label")
        case .setUserAgent: return NSLocalizedString("切换浏览模式", comment: "Browser Agent action label")
        case .setViewport: return NSLocalizedString("调整页面视口", comment: "Browser Agent action label")
        case .evaluateJavaScript: return NSLocalizedString("执行页面脚本", comment: "Browser Agent action label")
        case .screenshot: return NSLocalizedString("截取页面", comment: "Browser Agent action label")
        case .fetch: return NSLocalizedString("获取网页资源", comment: "Browser Agent action label")
        case .download: return NSLocalizedString("下载网页资源", comment: "Browser Agent action label")
        case .closeTab: return NSLocalizedString("关闭标签页", comment: "Browser Agent action label")
        }
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
        .guideSettingsPageContext(
            id: "settings-browser-agent-profile",
            title: NSLocalizedString("浏览器设置", comment: "Browser Agent settings guide title"),
            documents: [GuideDocumentReference(id: "browser-agent", title: "Browser Agent")],
            settings: [
                .bool("persistent_profile_enabled", label: NSLocalizedString("保留网站登录状态", comment: "向导设置字段"), get: { persistentProfileEnabled }, set: { persistentProfileEnabled = $0 }),
                .readOnly("session_available", label: NSLocalizedString("聊天会话可用", comment: "向导设置字段"), value: { .bool(sessionID != nil) })
            ]
        )
    }
}

private struct BrowserAgentWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
