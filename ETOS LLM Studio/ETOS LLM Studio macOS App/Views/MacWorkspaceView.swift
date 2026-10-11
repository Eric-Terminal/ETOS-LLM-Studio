import AppKit
import ETOSCore
import SwiftUI

struct MacWorkspaceView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var permissions = ToolPermissionCenter.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var sessionToEdit: ChatSession?
    @State private var sessionToDelete: ChatSession?
    @State private var sessionToBind: ChatSession?
    @State private var sessionToRoleplay: ChatSession?
    @State private var sessionToAnalyze: ChatSession?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSessionLibrarySidebar(model: workspace.sessionLibrary)
        } content: {
            MacSessionListView(model: workspace.sessionLibrary, edit: { sessionToEdit = $0 }, delete: { sessionToDelete = $0 }, analyze: showAnalytics)
        } detail: {
            MacChatView(showSessions: {
                workspace.sessionLibrary.scope = .all; workspace.sessionLibrary.query = ""; columnVisibility = .all
            }, showsSessionAnalytics: sessionToAnalyze != nil)
                .navigationTitle(workspace.currentSession?.name ?? NSLocalizedString("新的对话", comment: ""))
                .toolbar {
                    ToolbarItem { MacChatQuickActionsView() }
                    ToolbarItemGroup {
                        Button {
                            if let session = workspace.currentSession { showAnalytics(session) }
                        } label: {
                            Label(NSLocalizedString("session_usage.title", value: "Conversation Analytics", comment: "会话分析统计入口"), systemImage: "chart.bar.xaxis")
                        }.disabled(workspace.currentSession == nil || !workspace.canManageLocalModels)
                        Button { sessionToRoleplay = workspace.currentSession } label: {
                            Label(NSLocalizedString("会话角色绑定", comment: ""), systemImage: "person.text.rectangle")
                        }
                        .disabled(workspace.currentSession == nil)
                        if configuration.modelPickerWorldbookShortcutEnabled {
                            Button { sessionToBind = workspace.currentSession } label: {
                                Label(NSLocalizedString("绑定世界书", comment: ""), systemImage: "books.vertical")
                            }
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        modelPicker
                    }
                    ToolbarItemGroup {
                        if workspace.currentSession?.preferredModelIdentifier != nil, let name = workspace.effectiveModelName {
                            LabeledContent(NSLocalizedString("当前模型", comment: ""), value: name)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            sessionToEdit = workspace.currentSession
                        } label: {
                            Label(NSLocalizedString("会话设置", comment: ""), systemImage: "slider.horizontal.3")
                        }
                        Menu {
                            Button(NSLocalizedString("分支提示词和对话记录", comment: "")) { workspace.branchSession() }
                            Button(NSLocalizedString("仅分支提示词", comment: "")) { workspace.branchSession(copyMessages: false) }
                        } label: { Label(NSLocalizedString("创建分支", comment: ""), systemImage: "arrow.triangle.branch") }
                            .disabled(!workspace.canModifyCurrentHistory)
                    }
                }
        }
    }

    private var presentedContent: some View {
        navigationContent
        // 压缩工作表必须保留“停止”；历史修改仍由各操作自身的互斥检查拦截。
        .disabled(workspace.isRestoringData || (workspace.isMutatingHistory && !workspace.contextCompression.isWorking))
        .sheet(item: $sessionToEdit) { session in
            MacSessionEditor(session: session)
        }
        .sheet(item: $sessionToBind) { MacWorldbookBindingView(model: workspace.worldbookModel, session: $0) }
        .sheet(item: $sessionToRoleplay) { MacRoleplayBindingView(session: $0) }
        .sheet(item: $sessionToAnalyze) { MacSessionUsageAnalyticsSheet(session: $0) }
        .sheet(item: Binding(
            get: { appLock.state == .locked ? nil : permissions.activeRequest },
            set: { _ in }
        )) { request in
            MacToolPermissionView(request: request)
                .interactiveDismissDisabled()
        }
        .confirmationDialog(NSLocalizedString("删除会话", comment: ""), isPresented: Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let sessionToDelete { workspace.deleteSession(sessionToDelete) }
                sessionToDelete = nil
            }
        }
        .networkConnectionApprovalHost(isEnabled: workspace.canManageLocalModels)
        .modifier(MacDailyPulseHost(model: workspace.dailyPulse))
        .modifier(MacFeedbackNotificationHost())
        .modifier(MacAppInformationHost())
        .overlay { if appLock.state == .locked { AppLockOverlayView() } }
    }

    var body: some View {
        presentedContent
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appLock.handleSceneDidEnterBackground()
            Task { await configuration.flushPendingWrites() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appLock.handleSceneDidBecomeActive()
        }
        .onChange(of: appLock.state) { _, state in
            permissions.setAutoPresentationBlocked(state == .locked, reason: "mac-app-lock")
            if state == .locked { sessionToAnalyze = nil }
        }
        .onChange(of: workspace.canManageLocalModels) { _, available in if !available { sessionToAnalyze = nil } }
        .onChange(of: workspace.currentSession?.id) { _, _ in sessionToAnalyze = nil }
        .onDisappear { sessionToAnalyze = nil }
        .onAppear {
            permissions.setAutoPresentationBlocked(appLock.state == .locked, reason: "mac-app-lock")
        }
        .onChange(of: configuration.appLanguage) { _, language in
            AppLanguageRuntime.apply(rawValue: language)
            workspace.refreshMessagePresentation()
        }
        .onChange(of: configuration.enableMarkdown) { _, _ in workspace.refreshMessagePresentation() }
    }

    private var modelPicker: some View {
        Picker(NSLocalizedString("全局模型", comment: ""), selection: Binding<String?>(
            get: { workspace.selectedModelID },
            set: { workspace.selectModel($0) }
        )) {
            Text(NSLocalizedString("选择模型", comment: "")).tag(String?.none)
            ForEach(workspace.models) { model in
                Text(model.model.displayName).tag(Optional(model.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 320)
        .help(NSLocalizedString("会话首选模型优先于全局选择；可在会话设置中修改。", comment: ""))
    }

    private func showAnalytics(_ session: ChatSession) {
        guard workspace.canManageLocalModels, appLock.state != .locked else { return }
        sessionToAnalyze = session
    }
}
