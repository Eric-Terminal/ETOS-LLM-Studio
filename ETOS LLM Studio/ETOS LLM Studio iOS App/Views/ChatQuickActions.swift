// ============================================================================
// ChatQuickActions.swift
// ============================================================================
// ETOS LLM Studio
//
// 统一描述聊天页可配置快捷功能及其设置界面。
// ============================================================================

import SwiftUI
import ETOSCore

enum ChatQuickAction: String, CaseIterable, Identifiable {
    case temporaryChat
    case settings
    case toolCenter
    case dailyPulse
    case usageAnalytics
    case memory
    case mcp
    case agentSkills
    case shortcuts
    case roleplay
    case worldbook
    case extendedFeatures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temporaryChat:
            return NSLocalizedString("临时对话", comment: "聊天快捷功能标题")
        case .settings:
            return NSLocalizedString("设置", comment: "聊天快捷功能标题")
        case .toolCenter:
            return NSLocalizedString("工具中心", comment: "聊天快捷功能标题")
        case .dailyPulse:
            return NSLocalizedString("每日脉冲", comment: "聊天快捷功能标题")
        case .usageAnalytics:
            return NSLocalizedString("用量统计", comment: "聊天快捷功能标题")
        case .memory:
            return NSLocalizedString("记忆系统", comment: "聊天快捷功能标题")
        case .mcp:
            return NSLocalizedString("MCP 工具集成", comment: "聊天快捷功能标题")
        case .agentSkills:
            return NSLocalizedString("Agent Skills", comment: "聊天快捷功能标题")
        case .shortcuts:
            return NSLocalizedString("快捷指令工具集成", comment: "聊天快捷功能标题")
        case .roleplay:
            return NSLocalizedString("角色扮演与酒馆兼容", comment: "聊天快捷功能标题")
        case .worldbook:
            return NSLocalizedString("世界书", comment: "聊天快捷功能标题")
        case .extendedFeatures:
            return NSLocalizedString("拓展功能", comment: "聊天快捷功能标题")
        }
    }

    var systemImage: String {
        switch self {
        case .temporaryChat: return "hand.raised"
        case .settings: return "gearshape"
        case .toolCenter: return "wrench"
        case .dailyPulse: return "sparkles"
        case .usageAnalytics: return "chart.bar"
        case .memory: return "brain"
        case .mcp: return "network"
        case .agentSkills: return "star"
        case .shortcuts: return "bolt"
        case .roleplay: return "theatermasks"
        case .worldbook: return "book"
        case .extendedFeatures: return "ellipsis.circle"
        }
    }
}

enum ChatQuickActionSelection {
    static let fallback: [ChatQuickAction] = [.temporaryChat]

    static func decode(_ rawValue: String) -> [ChatQuickAction] {
        let selectedIDs = Set(rawValue.split(separator: ",").map(String.init))
        let actions = ChatQuickAction.allCases.filter { selectedIDs.contains($0.rawValue) }
        return actions.isEmpty ? fallback : actions
    }

    static func encode(_ actions: [ChatQuickAction]) -> String {
        let selectedIDs = Set(actions.map(\.rawValue))
        let normalized = ChatQuickAction.allCases.filter { selectedIDs.contains($0.rawValue) }
        return (normalized.isEmpty ? fallback : normalized).map(\.rawValue).joined(separator: ",")
    }
}

struct ChatQuickActionSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedActions: [ChatQuickAction] = ChatQuickActionSelection.fallback

    var body: some View {
        List {
            Section {
                ForEach(ChatQuickAction.allCases) { action in
                    Button {
                        toggle(action)
                    } label: {
                        HStack {
                            Label(action.title, systemImage: action.systemImage)
                            Spacer()
                            if selectedActions.contains(action) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedActions.count == 1 && selectedActions.contains(action))
                }
            } footer: {
                Text(NSLocalizedString("选择一个功能时会直接执行；选择多个功能时，聊天页按钮会展开快捷菜单。至少保留一个功能。", comment: "聊天快捷功能设置说明"))
            }
        }
        .navigationTitle(NSLocalizedString("聊天快捷功能", comment: "聊天快捷功能设置页标题"))
        .onAppear(perform: reloadSelection)
        .onChange(of: appConfig.chatQuickActionIDs) { _, _ in
            reloadSelection()
        }
    }

    private func toggle(_ action: ChatQuickAction) {
        if let index = selectedActions.firstIndex(of: action) {
            guard selectedActions.count > 1 else { return }
            selectedActions.remove(at: index)
        } else {
            selectedActions.append(action)
        }
        appConfig.chatQuickActionIDs = ChatQuickActionSelection.encode(selectedActions)
    }

    private func reloadSelection() {
        selectedActions = ChatQuickActionSelection.decode(appConfig.chatQuickActionIDs)
    }
}

extension ChatView {
    @ViewBuilder
    var navBarQuickActionButton: some View {
        if selectedChatQuickActions.count > 1 {
            Menu {
                ForEach(selectedChatQuickActions) { action in
                    if action == .temporaryChat {
                        Toggle(isOn: temporaryChatBinding) {
                            Label(action.title, systemImage: singleQuickActionSystemImage(for: action))
                        }
                    } else {
                        Button {
                            performQuickAction(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            } label: {
                navBarIconLabel(
                    systemName: "ellipsis",
                    accessibilityLabel: NSLocalizedString("快捷功能", comment: "聊天快捷菜单无障碍标签")
                )
            }
            .buttonStyle(.plain)
        } else if let action = selectedChatQuickActions.first {
            Button {
                performQuickAction(action)
            } label: {
                navBarIconLabel(
                    systemName: singleQuickActionSystemImage(for: action),
                    accessibilityLabel: action.title
                )
            }
            .buttonStyle(.plain)
        }
    }

    var temporaryChatBinding: Binding<Bool> {
        Binding(
            get: { isTemporaryChatEnabled },
            set: { setTemporaryChatEnabled($0) }
        )
    }

    func singleQuickActionSystemImage(for action: ChatQuickAction) -> String {
        guard action == .temporaryChat, isTemporaryChatEnabled else {
            return action.systemImage
        }
        return "hand.raised.fill"
    }

    func performQuickAction(_ action: ChatQuickAction) {
        if action == .temporaryChat {
            setTemporaryChatEnabled(!isTemporaryChatEnabled)
        } else {
            navigationDestination = action
        }
    }

    func setTemporaryChatEnabled(_ isEnabled: Bool) {
        if isEnabled {
            viewModel.enableTemporaryChat()
        } else {
            viewModel.saveCurrentTemporarySession()
        }
        isTemporaryChatEnabled = isEnabled
    }

    func refreshTemporaryChatState() {
        isTemporaryChatEnabled = viewModel.isTemporaryChatEnabled(for: viewModel.currentSession?.id)
    }

    func reloadChatQuickActions() {
        selectedChatQuickActions = ChatQuickActionSelection.decode(appConfig.chatQuickActionIDs)
    }

    @ViewBuilder
    func quickActionDestinationView(for action: ChatQuickAction) -> some View {
        switch action {
        case .temporaryChat:
            EmptyView()
        case .settings:
            SettingsView()
        case .toolCenter:
            ToolCenterView().environmentObject(viewModel)
        case .dailyPulse:
            DailyPulseView().environmentObject(viewModel)
        case .usageAnalytics:
            UsageAnalyticsView()
        case .memory:
            LongTermMemoryFeatureView().environmentObject(viewModel)
        case .mcp:
            MCPIntegrationView()
        case .agentSkills:
            AgentSkillsView()
        case .shortcuts:
            ShortcutIntegrationView()
        case .roleplay:
            RoleplaySettingsView().environmentObject(viewModel)
        case .worldbook:
            WorldbookSettingsView().environmentObject(viewModel)
        case .extendedFeatures:
            ExtendedFeaturesView().environmentObject(viewModel)
        }
    }
}
