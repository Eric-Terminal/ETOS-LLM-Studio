// ============================================================================
// BrowserAgentWatchFeatureView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS Browser Agent 使用运行时能力探测。用户可手动操作本机网页，也可明确
// 选择把模型操作委托给可达的 iPhone；不支持的动作会返回真实错误。
// ============================================================================

import SwiftUI
import ETOSCore

struct BrowserAgentWatchFeatureView: View {
    let sessionID: UUID?

    @ObservedObject private var manager = BrowserSessionManager.shared
    @State private var address = "https://"
    @State private var delegateToIPhone = AppConfigStore.boolValue(for: .browserAgentDelegateToIPhone)
    @State private var persistentProfileEnabled = false
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
                    let tabs = manager.tabs(sessionID: sessionID)
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

            Section {
                let capabilities = manager.capabilities()
                Text(String(format: NSLocalizedString("导航：%@", comment: "Watch Browser Agent navigation capability"), capabilityText(capabilities.supportsNavigation)))
                Text(String(format: NSLocalizedString("页面交互：%@", comment: "Watch Browser Agent interaction capability"), capabilityText(capabilities.supportsClick)))
                Text(String(format: NSLocalizedString("截图：%@", comment: "Watch Browser Agent screenshot capability"), capabilityText(capabilities.supportsScreenshot)))
            } header: {
                Text(NSLocalizedString("实验性本机能力", comment: "Watch Browser Agent capabilities section"))
            } footer: {
                Text(NSLocalizedString("能力来自当前 watchOS 运行时探测；系统不提供公开 WebKit API。", comment: "Watch Browser Agent capability probe footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("Browser Agent", comment: "Browser Agent settings title"))
        .task(id: sessionID) {
            guard let sessionID else {
                persistentProfileEnabled = false
                return
            }
            let profile = await Task.detached(priority: .utility) {
                Persistence.browserAgentDataProfile(sessionID: sessionID)
            }.value
            persistentProfileEnabled = profile == .persistentShared
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
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func capabilityText(_ value: Bool) -> String {
        value
            ? NSLocalizedString("支持", comment: "Capability supported")
            : NSLocalizedString("不支持", comment: "Capability unsupported")
    }
}

private struct BrowserAgentWatchTakeoverView: View {
    let sessionID: UUID
    let tabID: UUID

    @ObservedObject private var manager = BrowserSessionManager.shared

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
        .onAppear { manager.setUserControlling(true, sessionID: sessionID) }
        .onDisappear { manager.setUserControlling(false, sessionID: sessionID) }
    }

    private var currentDomain: String? {
        manager.tabs(sessionID: sessionID)
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
