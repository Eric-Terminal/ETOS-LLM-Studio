// ============================================================================
// BrowserAgentFeatureView.swift
// ============================================================================
// ETOS LLM Studio
//
// Browser Agent 的 iOS 管理与用户接管入口。该入口不受 Chat/Agent 模式限制；
// 模式只决定是否向模型暴露 browser_control。
// ============================================================================

import SwiftUI
import WebKit
import ETOSCore

struct BrowserAgentFeatureView: View {
    let sessionID: UUID?

    @ObservedObject private var manager = BrowserSessionManager.shared
    @State private var address = "https://"
    @State private var persistentProfileEnabled = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Label(
                    NSLocalizedString("Agent 与用户共享标签页", comment: "Browser Agent shared tabs title"),
                    systemImage: "hand.tap"
                )
                Text(NSLocalizedString("Agent 模式下，模型可以操作当前会话的浏览器；你随时可以进入同一标签页接管。Chat 模式不会向模型提供浏览器工具，但手动浏览仍然可用。", comment: "Browser Agent behavior explanation"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
                .disabled(sessionID == nil)
            } footer: {
                Text(NSLocalizedString("这是当前聊天会话的选择。关闭时，新标签页使用临时网站数据；切换只影响之后创建的标签页和新的 Agent Run。", comment: "Browser Agent profile footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(NSLocalizedString("网页地址", comment: "Browser Agent address field"), text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    openAddress()
                } label: {
                    Label(NSLocalizedString("打开网页", comment: "Browser Agent open page button"), systemImage: "safari")
                }
                .disabled(sessionID == nil || isWorking)

                Button {
                    openBlankTab()
                } label: {
                    Label(NSLocalizedString("新建空白标签页", comment: "Browser Agent new blank tab button"), systemImage: "plus.square.on.square")
                }
                .disabled(sessionID == nil || isWorking)
            } header: {
                Text(NSLocalizedString("打开", comment: "Browser Agent open section"))
            }

            Section {
                if let sessionID {
                    let tabs = manager.tabs(sessionID: sessionID)
                    if tabs.isEmpty {
                        Text(NSLocalizedString("当前会话还没有浏览器标签页。", comment: "Browser Agent empty tabs"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tabs) { tab in
                            NavigationLink {
                                BrowserAgentTakeoverView(sessionID: sessionID, tabID: tab.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(tab.title)
                                    if let url = tab.url {
                                        Text(url)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    close(tabID: tab.id)
                                } label: {
                                    Label(NSLocalizedString("关闭", comment: "Close browser tab"), systemImage: "xmark")
                                }
                            }
                        }
                    }
                } else {
                    Text(NSLocalizedString("请先打开一个聊天会话。", comment: "Browser Agent requires chat session"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(NSLocalizedString("当前会话的标签页", comment: "Browser Agent tabs section"))
            } footer: {
                Text(NSLocalizedString("不同聊天会话使用不同的标签页集合、截图和下载目录。", comment: "Browser Agent session isolation footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                let capabilities = manager.capabilities()
                LabeledContent(NSLocalizedString("导航", comment: "Browser Agent navigation capability"), value: capabilityText(capabilities.supportsNavigation))
                LabeledContent(NSLocalizedString("页面交互", comment: "Browser Agent interaction capability"), value: capabilityText(capabilities.supportsClick && capabilities.supportsTyping))
                LabeledContent(NSLocalizedString("截图与下载", comment: "Browser Agent capture capability"), value: capabilityText(capabilities.supportsScreenshot && capabilities.supportsDownload))
            } header: {
                Text(NSLocalizedString("本机能力", comment: "Browser Agent local capabilities section"))
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
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await manager.openTab(sessionID: sessionID, url: url)
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
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func close(tabID: UUID) {
        guard let sessionID else { return }
        do {
            _ = try manager.closeTab(sessionID: sessionID, tabID: tabID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func capabilityText(_ value: Bool) -> String {
        value
            ? NSLocalizedString("支持", comment: "Capability supported")
            : NSLocalizedString("不支持", comment: "Capability unsupported")
    }
}

private struct BrowserAgentTakeoverView: View {
    let sessionID: UUID
    let tabID: UUID

    @ObservedObject private var manager = BrowserSessionManager.shared

    var body: some View {
        Group {
            if let webView = try? manager.webView(sessionID: sessionID, tabID: tabID) {
                BrowserAgentWebView(webView: webView)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    NSLocalizedString("标签页已关闭", comment: "Browser Agent closed tab placeholder"),
                    systemImage: "safari"
                )
            }
        }
        .navigationTitle(NSLocalizedString("浏览器", comment: "Browser Agent takeover title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if let domain = currentDomain {
                Label(domain, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal)
            }
        }
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

private struct BrowserAgentWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
