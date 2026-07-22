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
    case contextCompression
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
        case .contextCompression:
            return NSLocalizedString("压缩为续聊", comment: "聊天快捷功能标题")
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
        case .temporaryChat: return "eye.slash"
        case .contextCompression: return "rectangle.compress.vertical"
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

    func systemImage(isTemporaryChatEnabled: Bool) -> String {
        guard self == .temporaryChat else { return systemImage }
        return isTemporaryChatEnabled ? "eye.slash" : "eye"
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

enum ChatQuickActionFolderLayout {
    static func estimatedColumnCount(actionCount: Int, usesAccessibilitySize: Bool) -> Int {
        if usesAccessibilitySize {
            return 2
        }
        return actionCount <= 4 ? 2 : 3
    }

    static func estimatedRowCount(actionCount: Int, columnCount: Int) -> Int {
        guard actionCount > 0, columnCount > 0 else { return 0 }
        return (actionCount + columnCount - 1) / columnCount
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
                Text(NSLocalizedString("选择一个功能时会直接执行；选择多个功能时，聊天页按钮会展开自适应快捷文件夹。至少保留一个功能。", comment: "聊天快捷功能设置说明"))
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
            Color.clear
                .frame(width: navBarIconSize, height: navBarIconSize)
                .accessibilityHidden(true)
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
            .disabled(!isQuickActionAvailable(action))
        }
    }

    func chatQuickActionFolderOverlay(viewportWidth: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            if isChatQuickActionFolderPresented {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        setChatQuickActionFolderPresented(false)
                    }
                    .accessibilityHidden(true)
            }

            ChatQuickActionFolderPanel(
                actions: selectedChatQuickActions,
                isTemporaryChatEnabled: isTemporaryChatEnabled,
                isTemporaryChatToggleAvailable: isQuickActionAvailable(.temporaryChat),
                isPresented: isChatQuickActionFolderPresented,
                collapsedSize: navBarIconSize,
                expandedWidth: min(max(220, viewportWidth - 32), 420),
                usesLiquidGlass: isLiquidGlassEnabled,
                onTogglePresentation: {
                    setChatQuickActionFolderPresented(!isChatQuickActionFolderPresented)
                },
                onPerform: performFolderQuickAction
            )
            .padding(.horizontal, 16)
            .padding(.top, navBarVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    func setChatQuickActionFolderPresented(_ isPresented: Bool) {
        if accessibilityReduceMotion {
            isChatQuickActionFolderPresented = isPresented
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                isChatQuickActionFolderPresented = isPresented
            }
        }
    }

    func singleQuickActionSystemImage(for action: ChatQuickAction) -> String {
        action.systemImage(isTemporaryChatEnabled: isTemporaryChatEnabled)
    }

    func performQuickAction(_ action: ChatQuickAction) {
        if action == .temporaryChat {
            guard isQuickActionAvailable(action) else { return }
            setTemporaryChatEnabled(!isTemporaryChatEnabled)
        } else if action == .contextCompression {
            guard let session = viewModel.currentSession,
                  !session.isTemporary,
                  !viewModel.allMessagesForSession.isEmpty || continuationContext != nil else { return }
            contextCompressionSourceSession = session
        } else {
            navigationDestination = action
        }
    }

    func performFolderQuickAction(_ action: ChatQuickAction) {
        if action == .temporaryChat {
            performQuickAction(action)
            return
        }

        setChatQuickActionFolderPresented(false)
        DispatchQueue.main.async {
            performQuickAction(action)
        }
    }

    func setTemporaryChatEnabled(_ isEnabled: Bool) {
        if isEnabled {
            viewModel.enableTemporaryChat()
        } else {
            viewModel.saveCurrentTemporarySession()
        }
        isTemporaryChatEnabled = isEnabled
        showChatTransientNotice(
            ChatTransientNotice(
                message: isEnabled
                    ? NSLocalizedString("临时对话已开启", comment: "临时对话状态提示")
                    : NSLocalizedString("临时对话已关闭", comment: "临时对话状态提示"),
                systemImage: ChatQuickAction.temporaryChat.systemImage(
                    isTemporaryChatEnabled: isEnabled
                ),
                tint: isEnabled ? .accentColor : .secondary
            )
        )
    }

    func refreshTemporaryChatState() {
        isTemporaryChatEnabled = viewModel.isTemporaryChatEnabled(for: viewModel.currentSession?.id)
    }

    func isQuickActionAvailable(_ action: ChatQuickAction) -> Bool {
        guard action == .temporaryChat else { return true }
        return TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: isTemporaryChatEnabled,
            hasConversationStarted: !viewModel.allMessagesForSession.isEmpty || continuationContext != nil
        )
    }

    func reloadChatQuickActions() {
        selectedChatQuickActions = ChatQuickActionSelection.decode(appConfig.chatQuickActionIDs)
        if selectedChatQuickActions.count <= 1 {
            setChatQuickActionFolderPresented(false)
        }
    }

    @ViewBuilder
    func quickActionDestinationView(for action: ChatQuickAction) -> some View {
        switch action {
        case .temporaryChat, .contextCompression:
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

private struct ChatQuickActionFolderPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumItemWidth: CGFloat = 78
    @ScaledMetric(relativeTo: .body) private var itemHeight: CGFloat = 86
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 46
    @ScaledMetric(relativeTo: .body) private var dismissButtonSize: CGFloat = 44

    let actions: [ChatQuickAction]
    let isTemporaryChatEnabled: Bool
    let isTemporaryChatToggleAvailable: Bool
    let isPresented: Bool
    let collapsedSize: CGFloat
    let expandedWidth: CGFloat
    let usesLiquidGlass: Bool
    let onTogglePresentation: () -> Void
    let onPerform: (ChatQuickAction) -> Void

    private var columns: [GridItem] {
        let count = ChatQuickActionFolderLayout.estimatedColumnCount(
            actionCount: actions.count,
            usesAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        return Array(repeating: GridItem(.flexible(minimum: minimumItemWidth), spacing: 8), count: count)
    }

    private var preferredHeight: CGFloat {
        let columnCount = ChatQuickActionFolderLayout.estimatedColumnCount(
            actionCount: actions.count,
            usesAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        let rowCount = ChatQuickActionFolderLayout.estimatedRowCount(
            actionCount: actions.count,
            columnCount: columnCount
        )
        let gridHeight = CGFloat(rowCount) * itemHeight + CGFloat(max(0, rowCount - 1)) * 8
        return min(max(gridHeight + 64, 150), 440)
    }

    var body: some View {
        let cornerRadius = isPresented ? CGFloat(24) : collapsedSize / 2
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Group {
            if #available(iOS 26.0, *), usesLiquidGlass {
                morphingContent
                    .background(shape.fill(glassOverlayColor))
                    .glassEffect(.clear.interactive(), in: shape)
                    .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                morphingContent
                    .background(
                        shape
                            .fill(.ultraThinMaterial)
                            .overlay(shape.fill(glassOverlayColor))
                            .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                            .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                    )
            }
        }
        .frame(
            width: isPresented ? expandedWidth : collapsedSize,
            height: isPresented ? preferredHeight : collapsedSize,
            alignment: .topTrailing
        )
        .clipShape(shape)
    }

    private var morphingContent: some View {
        // 入口与面板保持为同一视图，让玻璃只改变尺寸与圆角而不重新入场。
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(NSLocalizedString("快捷功能", comment: "聊天快捷文件夹标题"))
                        .font(.headline)

                    Spacer()

                    Color.clear
                        .frame(width: dismissButtonSize, height: dismissButtonSize)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(actions) { action in
                            actionButton(for: action)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding()
            .frame(width: expandedWidth, height: preferredHeight)
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(isPresented ? 1 : 0.96, anchor: .topTrailing)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)

            Button(action: onTogglePresentation) {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isPresented ? dismissButtonSize : collapsedSize,
                           height: isPresented ? dismissButtonSize : collapsedSize)
                    .background(Color.primary.opacity(isPresented ? 0.08 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(isPresented ? 16 : 0)
            .accessibilityLabel(
                isPresented
                    ? NSLocalizedString("收起快捷功能", comment: "收起聊天快捷文件夹按钮")
                    : NSLocalizedString("快捷功能", comment: "聊天快捷菜单无障碍标签")
            )
        }
        .frame(
            width: isPresented ? expandedWidth : collapsedSize,
            height: isPresented ? preferredHeight : collapsedSize,
            alignment: .topTrailing
        )
    }

    private var glassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }

    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }

    private func actionButton(for action: ChatQuickAction) -> some View {
        Button {
            onPerform(action)
        } label: {
            VStack {
                Image(systemName: systemImage(for: action))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: iconSize, height: iconSize)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                Text(action.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: itemHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChatQuickActionFolderButtonStyle())
        .disabled(action == .temporaryChat && !isTemporaryChatToggleAvailable)
        .accessibilityLabel(action.title)
    }

    private func systemImage(for action: ChatQuickAction) -> String {
        action.systemImage(isTemporaryChatEnabled: isTemporaryChatEnabled)
    }
}

private struct ChatQuickActionFolderButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !accessibilityReduceMotion ? 0.96 : 1)
            .animation(
                accessibilityReduceMotion
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.28, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}
