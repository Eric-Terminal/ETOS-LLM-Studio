import ETOSCore
import SwiftUI
import WebKit

struct MacBrowserView: View {
    let sessionID: UUID?
    let isTemporary: Bool
    let isActive: Bool
    @ObservedObject var model: MacBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var lease = UUID()
    @State private var visible = false
    @State private var showsSettings = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    private var active: Bool { visible && isActive && !model.isSuspended && model.lease == lease && model.sessionID == sessionID }

    var body: some View {
        VStack(spacing: 0) {
            if sessionID == nil {
                ContentUnavailableView(NSLocalizedString("请先打开一个聊天会话。", comment: ""), systemImage: "safari")
            } else if active {
                HStack {
                    Button { model.back() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel(NSLocalizedString("后退", comment: "")).disabled(!model.canControl || !model.canGoBack)
                    Button { model.forward() } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel(NSLocalizedString("前进", comment: "")).disabled(!model.canControl || !model.canGoForward)
                    TextField(NSLocalizedString("搜索或输入网页地址", comment: ""), text: $address)
                        .focused($addressFocused).onSubmit { model.navigate(address) }.disabled(!model.canControl)
                    if model.isLoading || model.isWorking {
                        Button { model.stop() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(NSLocalizedString("停止载入", comment: "")).disabled(model.control.controller != .user)
                    } else {
                        Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(NSLocalizedString("重新载入", comment: "")).disabled(!model.canControl || model.webView == nil)
                    }
                    Button { model.navigate() } label: { Image(systemName: "plus") }
                        .accessibilityLabel(NSLocalizedString("新建标签页", comment: "")).disabled(!model.canControl)
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(NSLocalizedString("浏览器设置", comment: ""))
                }.padding().buttonStyle(.borderless)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.tabs) { tab in
                            Button { model.select(tab.id) } label: {
                                Label(tab.title, systemImage: tab.id == model.selectedTabID ? "circle.inset.filled" : "circle")
                                    .lineLimit(1)
                            }.contextMenu {
                                Button(NSLocalizedString("关闭标签页", comment: "")) { model.close(tab.id) }
                            }
                        }
                    }.padding(.horizontal).buttonStyle(.borderless).disabled(!model.canControl)
                }
                HStack {
                    Text(controlTitle).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.control.controller == .user {
                        Button(NSLocalizedString("交还给 Agent", comment: "")) { model.release() }
                    } else {
                        Button(NSLocalizedString("接管", comment: "")) { model.takeOver() }
                    }
                }.padding().buttonStyle(.borderless)
                Divider()
                if let webView = model.webView {
                    if let viewport = model.viewport {
                        ScrollView([.horizontal, .vertical]) {
                            MacBrowserWebView(webView: webView).frame(width: viewport.width, height: viewport.height)
                        }.id(model.selectedTabID).allowsHitTesting(model.control.controller == .user)
                    } else {
                        MacBrowserWebView(webView: webView).id(model.selectedTabID)
                            .allowsHitTesting(model.control.controller == .user)
                    }
                } else if !model.isLoaded {
                    ProgressView(NSLocalizedString("处理中", comment: "")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(NSLocalizedString("没有打开的标签页", comment: ""), systemImage: "safari")
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled).padding() }
            } else { ProgressView(NSLocalizedString("处理中", comment: "")) }
        }
        .navigationTitle(NSLocalizedString("浏览器", comment: ""))
        .frame(minWidth: 700, minHeight: 500)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } } }
        .onAppear { visible = true; open() }
        .onDisappear { visible = false; model.leave(lease: lease) }
        .onChange(of: sessionID) { _, _ in model.leave(lease: lease); lease = UUID(); open() }
        .onChange(of: isActive) { _, value in if !value { model.leave(lease: lease); showsSettings = false } else { open() } }
        .onChange(of: model.epoch) { _, _ in showsSettings = false; dismiss() }
        .onChange(of: model.isSuspended) { _, value in if !value { open() } }
        .onChange(of: model.currentAddress) { _, value in if !addressFocused { address = value } }
        .sheet(isPresented: $showsSettings) { MacBrowserSettingsView(model: model, lease: lease, isActive: active) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-browser-\(lease)-\(model.epoch)"), title: NSLocalizedString("浏览器", comment: ""),
            documents: [GuideDocumentReference(id: "browser-agent", title: "Browser Agent")], isActive: active && !showsSettings,
            settings: [
                .readOnly("session_id", label: NSLocalizedString("对话", comment: ""), value: { .string(sessionID?.uuidString ?? "") }),
                .readOnly("tab_count", label: NSLocalizedString("标签页", comment: ""), value: { .int(model.tabs.count) }),
                .readOnly("selected_tab_id", label: NSLocalizedString("当前标签页", comment: ""), value: { .string(model.selectedTabID?.uuidString ?? "") }),
                .readOnly("controller", label: NSLocalizedString("浏览器控制状态", comment: ""), value: { .string(model.control.controller.rawValue) }),
                .readOnly("loading", label: NSLocalizedString("处理中", comment: ""), value: { .bool(model.isLoading || model.isWorking) }),
                .readOnly("manual_navigation_required", label: NSLocalizedString("浏览器", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private var controlTitle: String {
        switch model.control.controller {
        case .user: return NSLocalizedString("用户正在控制浏览器", comment: "")
        case .agent: return NSLocalizedString("Agent 正在操作网页", comment: "")
        case .returningToAgent: return NSLocalizedString("正在把页面交还给 Agent", comment: "")
        case .idle: return NSLocalizedString("空闲", comment: "")
        }
    }

    private func open() {
        guard visible, isActive, let sessionID else { return }
        address = ""; model.open(sessionID: sessionID, persisted: !isTemporary, lease: lease)
    }
}

private struct MacBrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView {
        // 标签页始终由 Core 持有，页面只借用；重新打开时复用登录和 DOM 状态。
        webView.removeFromSuperview()
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
