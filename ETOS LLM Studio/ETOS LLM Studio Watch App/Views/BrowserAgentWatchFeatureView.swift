// ============================================================================
// BrowserAgentWatchFeatureView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS Browser Agent 使用运行时能力探测。用户可手动操作本机网页，也可明确
// 选择把模型操作委托给可达的 iPhone；不支持的动作会返回真实错误。
// ============================================================================

import SwiftUI
import Combine
import ETOSCore

struct BrowserAgentWatchFeatureView: View {
    let sessionID: UUID?

    @ObservedObject private var manager = BrowserSessionManager.shared
    @State private var address = "https://"
    @State private var delegateToIPhone = AppConfigStore.boolValue(for: .browserAgentDelegateToIPhone)
    @State private var persistentProfileEnabled = false
    @State private var unavailableCapabilities: [BrowserAgentCapability] = []
    @State private var tabs: [BrowserAgentTabSummary] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Toggle(
                    NSLocalizedString("模型操作委托给 iPhone", comment: "Watch Browser Agent delegate toggle"),
                    isOn: $delegateToIPhone
                )
                .onChange(of: delegateToIPhone) { _, newValue in
                    AppConfigStore.persistSynchronously(.bool(newValue), for: .browserAgentDelegateToIPhone)
                }
            } footer: {
                Text(NSLocalizedString("关闭时使用手表本机的实验性 WebKit；开启后仅模型操作委托给可达的 iPhone，手动标签页仍在本机。", comment: "Watch Browser Agent delegation footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    NSLocalizedString("保留网站登录状态", comment: "Browser Agent persistent profile toggle"),
                    isOn: $persistentProfileEnabled
                )
                .buttonStyle(.plain)
                .onChange(of: persistentProfileEnabled) { _, newValue in
                    guard let sessionID else { return }
                    let profile: BrowserAgentDataProfile = newValue ? .persistentShared : .sessionIsolated
                    Task.detached(priority: .utility) {
                        _ = Persistence.saveBrowserAgentDataProfile(profile, sessionID: sessionID)
                    }
                }
                .disabled(sessionID == nil)
            } footer: {
                Text(NSLocalizedString("按聊天会话保存；用于 iPhone 委托和新的 Agent Run。手表本机实验性 WebKit 的数据隔离能力由当前系统决定。", comment: "Watch Browser Agent profile footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(NSLocalizedString("网页地址", comment: "Browser Agent address field"), text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    openAddress()
                } label: {
                    Label(NSLocalizedString("打开网页", comment: "Browser Agent open page button"), systemImage: "safari")
                }
                .buttonStyle(.plain)
                .disabled(sessionID == nil)
            }

            Section {
                if let sessionID {
                    if tabs.isEmpty {
                        Text(NSLocalizedString("还没有本机标签页。", comment: "Watch Browser Agent empty tabs"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tabs) { tab in
                            NavigationLink {
                                BrowserAgentWatchTakeoverView(sessionID: sessionID, tabID: tab.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(tab.title)
                                    if let url = tab.url {
                                        Text(url)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text(NSLocalizedString("请先打开一个聊天会话。", comment: "Browser Agent requires chat session"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(NSLocalizedString("本机标签页", comment: "Watch Browser Agent local tabs section"))
            }

            if !unavailableCapabilities.isEmpty {
                Section {
                    ForEach(unavailableCapabilities, id: \.self) { capability in
                        Label(capabilityLabel(capability), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(NSLocalizedString("本机限制", comment: "Watch Browser Agent capability limitations section"))
                } footer: {
                    Text(NSLocalizedString("这里只显示当前 watchOS 运行时缺少的能力；没有缺口时不会显示此区域。可选择把模型操作委托给 iPhone。", comment: "Watch Browser Agent capability limitations footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("Browser Agent", comment: "Browser Agent settings title"))
        .task(id: sessionID) {
            unavailableCapabilities = manager.capabilities().unavailableCapabilities
            refreshTabs()
            guard let sessionID else {
                persistentProfileEnabled = false
                return
            }
            let profile = await Task.detached(priority: .utility) {
                Persistence.browserAgentDataProfile(sessionID: sessionID)
            }.value
            persistentProfileEnabled = profile == .persistentShared
        }
        .onReceive(manager.objectWillChange) { _ in
            Task { @MainActor in
                await Task.yield()
                refreshTabs()
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

    private func openAddress() {
        guard let sessionID else { return }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: normalized) else {
            errorMessage = NSLocalizedString("网页地址无效。", comment: "Browser Agent invalid address")
            return
        }
        Task {
            do {
                _ = try await manager.openTab(sessionID: sessionID, url: url)
                refreshTabs()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshTabs() {
        tabs = sessionID.map { manager.tabs(sessionID: $0) } ?? []
    }

    private func capabilityLabel(_ capability: BrowserAgentCapability) -> String {
        switch capability {
        case .navigation:
            return NSLocalizedString("导航不可用", comment: "Watch Browser Agent navigation unavailable")
        case .snapshot:
            return NSLocalizedString("页面快照不可用", comment: "Watch Browser Agent snapshot unavailable")
        case .click:
            return NSLocalizedString("点击不可用", comment: "Watch Browser Agent click unavailable")
        case .typing:
            return NSLocalizedString("文字输入不可用", comment: "Watch Browser Agent typing unavailable")
        case .scrolling:
            return NSLocalizedString("滚动不可用", comment: "Watch Browser Agent scrolling unavailable")
        case .javaScript:
            return NSLocalizedString("JavaScript 不可用", comment: "Watch Browser Agent JavaScript unavailable")
        case .screenshot:
            return NSLocalizedString("截图不可用", comment: "Watch Browser Agent screenshot unavailable")
        case .download:
            return NSLocalizedString("下载不可用", comment: "Watch Browser Agent download unavailable")
        case .userTakeover:
            return NSLocalizedString("用户接管不可用", comment: "Watch Browser Agent takeover unavailable")
        }
    }
}

private struct BrowserAgentWatchTakeoverView: View {
    let sessionID: UUID
    let tabID: UUID

    @ObservedObject private var manager = BrowserSessionManager.shared
    @State private var currentDomain: String?

    var body: some View {
        Group {
            if let webView = try? BrowserSessionManager.shared.webView(sessionID: sessionID, tabID: tabID) {
                VStack {
                    if let domain = currentDomain {
                        Label(domain, systemImage: "lock.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    BrowserAgentWatchWebView(webView: webView)
                        .ignoresSafeArea()
                }
            } else {
                Text(NSLocalizedString("标签页已关闭", comment: "Browser Agent closed tab placeholder"))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("浏览器", comment: "Browser Agent takeover title"))
        .onAppear {
            manager.setUserControlling(true, sessionID: sessionID)
            refreshDomain()
        }
        .onReceive(manager.objectWillChange) { _ in
            Task { @MainActor in
                await Task.yield()
                refreshDomain()
            }
        }
        .onDisappear { manager.setUserControlling(false, sessionID: sessionID) }
    }

    private func refreshDomain() {
        currentDomain = manager.tabs(sessionID: sessionID)
            .first(where: { $0.id == tabID })?
            .url
            .flatMap(URL.init(string:))?
            .host
    }
}

private struct BrowserAgentWatchWebView: _UIViewRepresentable {
    typealias UIViewType = NSObject

    let webView: NSObject

    func makeUIView(context: Context) -> NSObject { webView }

    func updateUIView(_ uiView: NSObject, context: Context) {}
}
