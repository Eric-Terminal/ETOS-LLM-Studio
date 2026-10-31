import ETOSCore
import SwiftUI

@MainActor
struct MacChatQuickActionsView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @StateObject private var model = MacChatQuickActionsModel()
    @State private var destination: MacChatQuickActionDestination?
    @State private var showsTemporaryIntroduction = false
    @State private var showsModelPicker = false
    @State private var visible = false
    private var available: Bool { visible && workspace.canManageLocalModels }

    var body: some View {
        Group {
            if let state = model.presentation {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        ForEach(state.toolbarRows) { entry($0) }
                        if !state.menuRows.isEmpty {
                            Menu {
                                ForEach(state.menuRows) { entry($0) }
                            } label: {
                                Label(NSLocalizedString("聊天快捷功能", comment: ""), systemImage: "ellipsis")
                            }
                        }
                    }
                    Menu {
                        ForEach(state.selectedRows) { entry($0) }
                    } label: {
                        Label(NSLocalizedString("聊天快捷功能", comment: ""), systemImage: "square.grid.2x2")
                    }
                }
            } else {
                Label(NSLocalizedString("聊天快捷功能", comment: ""), systemImage: "square.grid.2x2").foregroundStyle(.secondary)
            }
        }
        .disabled(!available || model.isPreparing)
        .sheet(item: $destination) { target in
            MacChatQuickActionSheet(target: target)
        }
        .popover(isPresented: $showsTemporaryIntroduction) {
            MacTemporaryChatIntroductionView(isActive: showsTemporaryIntroduction && available)
        }
        .sheet(isPresented: $showsModelPicker) { MacSlashCommandModelPicker() }
        .onAppear { visible = true; model.setActive(available) }
        .onDisappear { visible = false; model.setActive(false); destination = nil; showsTemporaryIntroduction = false; showsModelPicker = false }
        .onChange(of: workspace.canManageLocalModels) { _, _ in
            model.setActive(available)
            if !available { showsTemporaryIntroduction = false }
        }
        .onChange(of: appLock.state) { _, state in if state == .locked { destination = nil; showsModelPicker = false } }
        .onChange(of: workspace.currentSession?.id) { _, _ in
            if destination?.page.requiresSession == true { destination = nil }
        }
        .onChange(of: workspace.linux.epoch) { _, _ in
            if destination?.page == .localTerminal { destination = nil }
        }
    }

    @ViewBuilder
    private func entry(_ row: MacChatQuickActionPresentation.Row) -> some View {
        switch row.action {
        case .modelPicker:
            Button { showsModelPicker = true } label: { Label(row.title, systemImage: row.systemImage) }
        case .temporaryChat: MacTemporaryChatMenu(showingIntroduction: $showsTemporaryIntroduction)
        case .settings: SettingsLink { Label(row.title, systemImage: row.systemImage) }
        case .dailyPulse: MacDailyPulseEntry(model: workspace.dailyPulse)
        case .contextCompression: MacContextCompressionEntry(model: workspace.contextCompression)
        default:
            if let page = MacChatQuickActionPage(rawValue: row.action.rawValue) {
                Button {
                    guard available, !page.requiresSession || workspace.currentSession != nil else { return }
                    guard page != .localTerminal || (configuration.localLinuxEnabled && !workspace.linux.isSuspended && !workspace.linux.isWorking) else { return }
                    guard page != .browser || !workspace.browser.isSuspended else { return }
                    destination = MacChatQuickActionDestination(page: page, sessionID: workspace.currentSession?.id,
                        isTemporary: workspace.temporaryChatMemoryMode != nil)
                } label: { Label(row.title, systemImage: row.systemImage) }
                    .disabled((page.requiresSession && workspace.currentSession == nil)
                        || (page == .browser && workspace.browser.isSuspended)
                        || (page == .localTerminal && (!configuration.localLinuxEnabled || workspace.linux.isSuspended || workspace.linux.isWorking)))
            }
        }
    }
}

@MainActor
struct MacChatQuickActionSheet: View {
    let target: MacChatQuickActionDestination
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    private var available: Bool {
        visible && workspace.canManageLocalModels && (!target.page.requiresSession || target.sessionID == workspace.currentSession?.id)
    }

    var body: some View {
        NavigationStack {
            page
                .navigationTitle(target.page.action.title)
                .toolbar { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } }
                .modifier(MacGuideInspector())
        }
        .frame(minWidth: 700, minHeight: 540)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .disabled(workspace.isRestoringData)
    }

    @ViewBuilder
    private var page: some View {
        switch target.page {
        case .toolCenter: MacToolCenterView(isActive: available)
        case .usageAnalytics: MacUsageAnalyticsView(isActive: available)
        case .memory: MacMemorySystemView(isActive: available)
        case .mcp: MacMCPListView(isActive: available)
        case .agentSkills: MacSkillsView(isActive: available, model: workspace.skills)
        case .shortcuts: MacShortcutToolsView(isActive: available, model: workspace.shortcutTools)
        case .roleplay: MacRoleplayLibraryView(model: workspace.roleplayModel)
        case .worldbook: MacWorldbookListView(model: workspace.worldbookModel)
        case .extendedFeatures: MacExtendedFeaturesView(isActive: available)
        case .browser:
            MacBrowserView(sessionID: target.sessionID, isTemporary: target.isTemporary, isActive: available, model: workspace.browser)
        case .localTerminal: MacLinuxTerminalView(isActive: available, runtime: workspace.linux)
        }
    }
}
