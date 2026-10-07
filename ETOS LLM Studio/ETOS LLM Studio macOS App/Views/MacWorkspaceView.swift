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

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { workspace.currentSession?.id },
                set: { workspace.selectSession($0) }
            )) {
                ForEach(workspace.visibleSessions) { session in
                    HStack {
                        Label(session.name, systemImage: session.isTemporary ? "bubble.left" : "bubble.left.and.bubble.right")
                            .lineLimit(2)
                        Spacer()
                        if workspace.runningSessionIDs.contains(session.id) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button(NSLocalizedString("编辑", comment: "")) { sessionToEdit = session }
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) { sessionToDelete = session }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("对话", comment: ""))
            .searchable(text: $workspace.searchText, prompt: NSLocalizedString("搜索会话", comment: ""))
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            .toolbar {
                Button { workspace.newSession() } label: {
                    Label(NSLocalizedString("新建对话", comment: ""), systemImage: "square.and.pencil")
                }
                SettingsLink {
                    Label(NSLocalizedString("设置", comment: ""), systemImage: "gearshape")
                }
            }
        } detail: {
            MacChatView()
                .navigationTitle(workspace.currentSession?.name ?? NSLocalizedString("新的对话", comment: ""))
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker(NSLocalizedString("模型", comment: ""), selection: Binding(
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
                    }
                    Button {
                        sessionToEdit = workspace.currentSession
                    } label: {
                        Label(NSLocalizedString("会话设置", comment: ""), systemImage: "slider.horizontal.3")
                    }
                }
        }
        .disabled(workspace.isRestoringData)
        .sheet(item: $sessionToEdit) { session in
            MacSessionEditor(session: session)
        }
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
        .networkConnectionApprovalHost()
        .overlay { if appLock.state == .locked { AppLockOverlayView() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appLock.handleSceneDidEnterBackground()
            Task { await configuration.flushPendingWrites() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appLock.handleSceneDidBecomeActive()
        }
        .onChange(of: appLock.state) { _, state in
            permissions.setAutoPresentationBlocked(state == .locked, reason: "mac-app-lock")
        }
        .onAppear {
            permissions.setAutoPresentationBlocked(appLock.state == .locked, reason: "mac-app-lock")
        }
        .onChange(of: configuration.appLanguage) { _, language in
            AppLanguageRuntime.apply(rawValue: language)
            workspace.refreshMessagePresentation()
        }
        .onChange(of: configuration.enableMarkdown) { _, _ in workspace.refreshMessagePresentation() }
    }
}

private struct MacSessionEditor: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChatSession
    @State private var isSaving = false
    @State private var error: String?
    private let original: ChatSession

    init(session: ChatSession) {
        original = session
        _draft = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("名称", comment: ""), text: $draft.name)
                    TextField(NSLocalizedString("系统提示词", comment: ""), text: Binding(
                        get: { draft.systemPrompt ?? "" },
                        set: { draft.systemPrompt = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(3...10)
                }
                Section {
                    Toggle(NSLocalizedString("隔离记忆上下文", comment: ""), isOn: $draft.memoryContextIsolationEnabled)
                    Toggle(NSLocalizedString("隔离工具上下文", comment: ""), isOn: $draft.toolContextIsolationEnabled)
                    Toggle(NSLocalizedString("隔离全局系统提示词", comment: ""), isOn: $draft.globalSystemPromptIsolationEnabled)
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("会话设置", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        isSaving = true
                        Task {
                            defer { isSaving = false }
                            do { try await workspace.saveSession(draft, replacing: original); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(isSaving || draft.name.isEmpty)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-session-\(draft.id)"),
                title: NSLocalizedString("会话设置", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: [
                    .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("draft_until_save") }),
                    .string("name", label: NSLocalizedString("名称", comment: ""), allowsEmpty: false, get: { draft.name }, set: { draft.name = $0 }),
                    .string("system_prompt", label: NSLocalizedString("系统提示词", comment: ""), get: { draft.systemPrompt ?? "" }, set: { draft.systemPrompt = $0.isEmpty ? nil : $0 }),
                    .bool("memory_isolation", label: NSLocalizedString("隔离记忆上下文", comment: ""), get: { draft.memoryContextIsolationEnabled }, set: { draft.memoryContextIsolationEnabled = $0 }),
                    .bool("tool_isolation", label: NSLocalizedString("隔离工具上下文", comment: ""), get: { draft.toolContextIsolationEnabled }, set: { draft.toolContextIsolationEnabled = $0 }),
                    .bool("prompt_isolation", label: NSLocalizedString("隔离全局系统提示词", comment: ""), get: { draft.globalSystemPromptIsolationEnabled }, set: { draft.globalSystemPromptIsolationEnabled = $0 })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 480, minHeight: 440)
    }
}
