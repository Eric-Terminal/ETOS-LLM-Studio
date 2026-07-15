// ============================================================================
// WatchInputQuickActions.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 watchOS 输入栏快捷功能的展示信息、配置界面与页面跳转。
// ============================================================================

import SwiftUI
import ETOSCore

extension WatchInputQuickActionEdge {
    var title: String {
        switch self {
        case .leading:
            return NSLocalizedString("左侧快捷功能", comment: "Watch input leading quick actions")
        case .trailing:
            return NSLocalizedString("右侧快捷功能", comment: "Watch input trailing quick actions")
        }
    }
}

extension WatchInputQuickAction {
    static let inputActions: [WatchInputQuickAction] = [
        .requestControls,
        .sessionHistory,
        .contextCompression,
        .roleplayScripts,
        .addAttachment,
        .clearInput
    ]

    static let destinationActions: [WatchInputQuickAction] = [
        .settings,
        .toolCenter,
        .dailyPulse,
        .usageAnalytics,
        .imageGallery,
        .memory,
        .mcp,
        .agentSkills,
        .shortcuts,
        .roleplay,
        .worldbook,
        .extendedFeatures
    ]

    var title: String {
        switch self {
        case .requestControls:
            return NSLocalizedString("请求控制", comment: "Watch input quick action")
        case .sessionHistory:
            return NSLocalizedString("历史会话", comment: "Watch input quick action")
        case .contextCompression:
            return NSLocalizedString("压缩为续聊", comment: "Watch input quick action")
        case .roleplayScripts:
            return NSLocalizedString("助手脚本", comment: "Watch input quick action")
        case .addAttachment:
            return NSLocalizedString("添加附件", comment: "Watch input quick action")
        case .clearInput:
            return NSLocalizedString("清空输入", comment: "Watch input quick action")
        case .settings:
            return NSLocalizedString("设置", comment: "Watch input quick action")
        case .toolCenter:
            return NSLocalizedString("工具中心", comment: "Watch input quick action")
        case .dailyPulse:
            return NSLocalizedString("每日脉冲", comment: "Watch input quick action")
        case .usageAnalytics:
            return NSLocalizedString("用量统计", comment: "Watch input quick action")
        case .imageGallery:
            return NSLocalizedString("图片相册", comment: "Watch input quick action")
        case .memory:
            return NSLocalizedString("记忆系统", comment: "Watch input quick action")
        case .mcp:
            return NSLocalizedString("MCP 工具集成", comment: "Watch input quick action")
        case .agentSkills:
            return NSLocalizedString("Agent Skills", comment: "Watch input quick action")
        case .shortcuts:
            return NSLocalizedString("快捷指令工具集成", comment: "Watch input quick action")
        case .roleplay:
            return NSLocalizedString("角色扮演与酒馆兼容", comment: "Watch input quick action")
        case .worldbook:
            return NSLocalizedString("世界书", comment: "Watch input quick action")
        case .extendedFeatures:
            return NSLocalizedString("拓展功能", comment: "Watch input quick action")
        }
    }

    var systemImage: String {
        switch self {
        case .requestControls: return "slider.vertical.3"
        case .sessionHistory: return "list.bullet.rectangle"
        case .contextCompression: return "rectangle.compress.vertical"
        case .roleplayScripts: return "curlybraces.square"
        case .addAttachment: return "plus"
        case .clearInput: return "trash"
        case .settings: return "gearshape"
        case .toolCenter: return "wrench"
        case .dailyPulse: return "sparkles"
        case .usageAnalytics: return "chart.bar"
        case .imageGallery: return "photo.on.rectangle.angled"
        case .memory: return "brain"
        case .mcp: return "network"
        case .agentSkills: return "star"
        case .shortcuts: return "bolt"
        case .roleplay: return "theatermasks"
        case .worldbook: return "book"
        case .extendedFeatures: return "ellipsis.circle"
        }
    }

    var tint: Color {
        switch self {
        case .requestControls, .agentSkills, .roleplay:
            return .purple
        case .sessionHistory, .addAttachment, .mcp:
            return .blue
        case .contextCompression, .roleplayScripts, .extendedFeatures:
            return .indigo
        case .clearInput:
            return .red
        case .settings:
            return .gray
        case .toolCenter:
            return .teal
        case .dailyPulse, .shortcuts:
            return .orange
        case .usageAnalytics:
            return .cyan
        case .imageGallery:
            return .pink
        case .memory:
            return .mint
        case .worldbook:
            return .brown
        }
    }
}

struct WatchInputQuickActionSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            quickActionSection(for: .leading)
            quickActionSection(for: .trailing)
        }
        .navigationTitle(NSLocalizedString("输入栏快捷功能", comment: "Watch input quick action settings title"))
    }

    private func quickActionSection(for edge: WatchInputQuickActionEdge) -> some View {
        Section {
            ForEach(appConfig.watchInputQuickActionSettings.actions(for: edge)) { action in
                Label(action.title, systemImage: action.systemImage)
            }
            .onDelete { offsets in
                deleteActions(at: offsets, from: edge)
            }
            .onMove { offsets, destination in
                moveActions(from: offsets, to: destination, in: edge)
            }

            NavigationLink {
                WatchInputQuickActionPickerView(targetEdge: edge)
            } label: {
                Label(
                    NSLocalizedString("添加快捷功能", comment: "Add watch input quick action"),
                    systemImage: "plus"
                )
            }
        } header: {
            Text(edge.title)
        } footer: {
            Text(NSLocalizedString("拖动可调整顺序，轻扫可删除；输入栏两侧会按这里的顺序显示。", comment: "Watch input quick action order guidance"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func deleteActions(at offsets: IndexSet, from edge: WatchInputQuickActionEdge) {
        var configuration = appConfig.watchInputQuickActionSettings
        var actions = configuration.actions(for: edge)
        actions.remove(atOffsets: offsets)
        configuration.setActions(actions, for: edge)
        appConfig.watchInputQuickActionSettings = configuration
    }

    private func moveActions(
        from source: IndexSet,
        to destination: Int,
        in edge: WatchInputQuickActionEdge
    ) {
        var configuration = appConfig.watchInputQuickActionSettings
        var actions = configuration.actions(for: edge)
        actions.move(fromOffsets: source, toOffset: destination)
        configuration.setActions(actions, for: edge)
        appConfig.watchInputQuickActionSettings = configuration
    }
}

private struct WatchInputQuickActionPickerView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    let targetEdge: WatchInputQuickActionEdge

    var body: some View {
        List {
            actionSection(
                title: NSLocalizedString("输入操作", comment: "Watch input quick action picker section"),
                actions: WatchInputQuickAction.inputActions
            )
            actionSection(
                title: NSLocalizedString("功能入口", comment: "Watch input quick action picker section"),
                actions: WatchInputQuickAction.destinationActions
            )
        }
        .navigationTitle(NSLocalizedString("添加快捷功能", comment: "Add watch input quick action"))
    }

    private func actionSection(
        title: String,
        actions: [WatchInputQuickAction]
    ) -> some View {
        Section {
            ForEach(actions) { action in
                Button {
                    assign(action)
                } label: {
                    HStack {
                        Label(action.title, systemImage: action.systemImage)
                        Spacer()
                        if let assignedEdge = assignedEdge(for: action) {
                            if assignedEdge == targetEdge {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            } else {
                                Text(assignedEdge.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(assignedEdge(for: action) == targetEdge)
            }
        } header: {
            Text(title)
        }
    }

    private func assignedEdge(for action: WatchInputQuickAction) -> WatchInputQuickActionEdge? {
        let configuration = appConfig.watchInputQuickActionSettings
        if configuration.leadingActions.contains(action) {
            return .leading
        }
        if configuration.trailingActions.contains(action) {
            return .trailing
        }
        return nil
    }

    private func assign(_ action: WatchInputQuickAction) {
        var configuration = appConfig.watchInputQuickActionSettings
        var leadingActions = configuration.leadingActions
        var trailingActions = configuration.trailingActions
        leadingActions.removeAll { $0 == action }
        trailingActions.removeAll { $0 == action }

        switch targetEdge {
        case .leading:
            leadingActions.append(action)
        case .trailing:
            trailingActions.append(action)
        }

        configuration = WatchInputQuickActionConfiguration(
            leadingActions: leadingActions,
            trailingActions: trailingActions
        )
        appConfig.watchInputQuickActionSettings = configuration
    }
}

extension ContentView {
    func performWatchInputQuickAction(_ action: WatchInputQuickAction) {
        switch action {
        case .sessionHistory:
            viewModel.activeSheet = nil
            isSettingsPresented = false
            settingsDestination = nil
            isSessionListPresented = true
        case .contextCompression:
            guard viewModel.currentSession?.isTemporary == false,
                  !viewModel.allMessagesForSession.isEmpty || continuationContext != nil else { return }
            isContextCompressionPresented = true
        case .settings:
            viewModel.activeSheet = nil
            settingsDestination = nil
            isSettingsPresented = true
        case .toolCenter,
             .dailyPulse,
             .usageAnalytics,
             .imageGallery,
             .memory,
             .mcp,
             .agentSkills,
             .shortcuts,
             .roleplay,
             .worldbook,
             .extendedFeatures:
            watchInputQuickActionDestination = action
        case .requestControls,
             .roleplayScripts,
             .addAttachment,
             .clearInput:
            break
        }
    }

    @ViewBuilder
    func watchInputQuickActionDestinationView(for action: WatchInputQuickAction) -> some View {
        switch action {
        case .toolCenter:
            ToolCenterView().environmentObject(viewModel)
        case .dailyPulse:
            DailyPulseView(viewModel: viewModel)
        case .usageAnalytics:
            UsageAnalyticsView()
        case .imageGallery:
            ImageGenerationFeatureView().environmentObject(viewModel)
        case .memory:
            LongTermMemoryFeatureView().environmentObject(viewModel)
        case .mcp:
            MCPIntegrationView()
        case .agentSkills:
            AgentSkillsView()
        case .shortcuts:
            ShortcutIntegrationView()
        case .roleplay:
            RoleplaySettingsView(viewModel: viewModel)
        case .worldbook:
            WorldbookSettingsView(viewModel: viewModel)
        case .extendedFeatures:
            ExtendedFeaturesView().environmentObject(viewModel)
        case .requestControls,
             .sessionHistory,
             .contextCompression,
             .roleplayScripts,
             .addAttachment,
             .clearInput,
             .settings:
            EmptyView()
        }
    }
}
