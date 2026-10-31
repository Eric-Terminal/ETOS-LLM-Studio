// ============================================================================
// ChatQuickActions.swift
// ============================================================================
// ETOS LLM Studio
//
// 统一描述聊天页可配置快捷功能及其设置界面。
// ============================================================================

import SwiftUI
import ETOSCore

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
    @State private var toolbarActions = Set<ChatQuickAction>()
    @State private var hiddenActions: [ChatQuickAction] = []
    @State private var preparedConfiguration = ""
    @State private var revision = UUID()
    @State private var editMode: EditMode = .inactive

    private var configurationID: String {
        appConfig.chatQuickActionIDs + "|" + appConfig.chatToolbarActionIDs + "|" + appConfig.appLanguage
    }

    var body: some View {
        List {
            Section {
                settingsIntroCard
            }
            Section {
                ForEach(selectedActions) { action in
                    placementPicker(action, enabled: true)
                }
                .onMove { offsets, destination in
                    var actions = selectedActions
                    actions.move(fromOffsets: offsets, toOffset: destination)
                    selectedActions = actions
                    appConfig.chatQuickActionIDs = ChatQuickActionSelection.encode(actions)
                }
            } header: {
                Text(NSLocalizedString("已选择的快捷功能", comment: ""))
            } footer: {
                Text(NSLocalizedString("chat.quickActions.orderFooter", value: "Use Edit to reorder. Keep at least one action enabled. Changes save immediately.", comment: "快捷功能排序说明"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(NSLocalizedString("chat.quickActions.placement.hidden", value: "Hidden", comment: "")) {
                ForEach(hiddenActions) { action in
                    placementPicker(action, enabled: false)
                }
            }
        }
        .disabled(preparedConfiguration != configurationID)
        .environment(\.editMode, $editMode)
        .toolbar {
            Button(editMode.isEditing ? NSLocalizedString("完成", comment: "") : NSLocalizedString("编辑", comment: "")) {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
        }
        .navigationTitle(NSLocalizedString("聊天快捷功能", comment: "聊天快捷功能设置页标题"))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "settings-chat-quick-actions-\(revision)"),
            title: NSLocalizedString("聊天快捷功能", comment: "聊天快捷功能向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings"),
                GuideDocumentReference(id: "chat-quick-actions", title: "Chat Quick Actions"),
                GuideDocumentReference(id: "adaptive-layout", title: "Adaptive Layout")],
            isActive: preparedConfiguration == configurationID,
            settings: [
                .readOnly("save_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("immediate") }),
                .json(
                    "actions",
                    label: NSLocalizedString("已选择的快捷功能", comment: "聊天快捷功能向导字段"),
                    schema: GuideChatQuickActionSettingsSupport.actionsSchema,
                    get: { .array(selectedActions.map { .string($0.rawValue) }) },
                    normalize: { value in
                        guard preparedConfiguration == configurationID else { throw GuideError.pageChanged }
                        let actions = try GuideChatQuickActionSettingsSupport.actions(from: value)
                        return .array(actions.map { .string($0.rawValue) })
                    },
                    set: { value in
                        guard preparedConfiguration == configurationID else { throw GuideError.pageChanged }
                        let actions = try GuideChatQuickActionSettingsSupport.actions(from: value)
                        selectedActions = actions
                        appConfig.chatQuickActionIDs = ChatQuickActionSelection.encode(actions)
                        preparedConfiguration = configurationID
                    }
                ),
                .json(
                    "toolbar_actions",
                    label: NSLocalizedString("chat.quickActions.placement.toolbar", value: "Prefer Toolbar", comment: ""),
                    schema: GuideChatQuickActionSettingsSupport.toolbarSchema,
                    get: { .array(ChatQuickAction.allCases.filter(toolbarActions.contains).map { .string($0.rawValue) }) },
                    normalize: { value in
                        guard preparedConfiguration == configurationID else { throw GuideError.pageChanged }
                        return .array(try GuideChatQuickActionSettingsSupport.actions(from: value, allowsEmpty: true).map { .string($0.rawValue) })
                    },
                    set: { value in
                        guard preparedConfiguration == configurationID else { throw GuideError.pageChanged }
                        let actions = try GuideChatQuickActionSettingsSupport.actions(from: value, allowsEmpty: true)
                        toolbarActions = Set(actions)
                        appConfig.chatToolbarActionIDs = ChatQuickActionSelection.encodeToolbarActions(Set(actions))
                        preparedConfiguration = configurationID
                    }
                )
            ]
        )
        .task(id: configurationID) {
            let identifier = configurationID
            let raw = appConfig.chatQuickActionIDs
            let toolbarRaw = appConfig.chatToolbarActionIDs
            let worker = Task.detached(priority: .userInitiated) {
                let selected = ChatQuickActionSelection.decode(raw)
                let selectedSet = Set(selected)
                return (selected, ChatQuickActionSelection.decodeToolbarActions(toolbarRaw),
                        ChatQuickAction.allCases.filter { !selectedSet.contains($0) })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, identifier == configurationID else { return }
            selectedActions = result.0
            toolbarActions = result.1
            hiddenActions = result.2
            preparedConfiguration = identifier
            revision = UUID()
        }
    }

    private var settingsIntroCard: some View {
        DisclosureGroup {
            Text(NSLocalizedString("chat.quickActions.introduction", value: "Choose Prefer Toolbar, More Menu, or Hidden for each action, including Choose Model. Reorder enabled actions with Edit. When space is limited, the system may move toolbar actions into More. iPhone Duo automatically switches between horizontal and vertical bars. The session list remains available. Changes save immediately and sync with Mac. On older iOS versions, enabled actions keep their order in the existing shortcut menu.", comment: "聊天快捷功能介绍"))
                .font(.footnote).foregroundStyle(.secondary)
        } label: {
            Label(NSLocalizedString("使用说明", comment: ""), systemImage: "info.circle")
        }
    }

    private func placementPicker(_ action: ChatQuickAction, enabled: Bool) -> some View {
        Picker(selection: Binding(
            get: { enabled ? (toolbarActions.contains(action) ? .toolbar : .menu) : .hidden },
            set: { (placement: ChatQuickActionPlacement) in
                var actions = selectedActions
                var toolbar = toolbarActions
                if placement == .hidden {
                    guard actions.count > 1 else { return }
                    actions.removeAll { $0 == action }
                } else if !enabled {
                    actions.append(action)
                }
                if placement == .toolbar { toolbar.insert(action) } else { toolbar.remove(action) }
                appConfig.chatQuickActionIDs = ChatQuickActionSelection.encode(actions)
                appConfig.chatToolbarActionIDs = ChatQuickActionSelection.encodeToolbarActions(toolbar)
            }
        )) {
            ForEach(ChatQuickActionPlacement.allCases) { placement in
                Text(placement.title).tag(placement)
                    .disabled(placement == .hidden && enabled && selectedActions.count == 1)
            }
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .pickerStyle(.menu)
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
                temporaryChatMemoryMode: temporaryChatMemoryMode,
                isTemporaryChatToggleAvailable: isQuickActionAvailable(.temporaryChat),
                isPresented: isChatQuickActionFolderPresented,
                collapsedSize: navBarIconSize,
                expandedWidth: min(max(220, viewportWidth - 32), 420),
                usesLiquidGlass: isLiquidGlassEnabled,
                glassTintOpacity: appConfig.liquidGlassTintOpacity,
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
        action.systemImage(
            isTemporaryChatEnabled: isTemporaryChatEnabled,
            memoryMode: temporaryChatMemoryMode
        )
    }

    func performQuickAction(_ action: ChatQuickAction) {
        if action == .modelPicker {
            presentModelPickerSheet()
        } else if action == .temporaryChat {
            guard isQuickActionAvailable(action) else { return }
            performTemporaryChatTap()
        } else if action == .contextCompression {
            guard let session = viewModel.currentSession,
                  !session.isTemporary,
                  !viewModel.allMessagesForSession.isEmpty || continuationContext != nil else { return }
            contextCompressionSourceSession = session
        } else {
            if action == .localTerminal {
                localTerminalInitialJobID = nil
            }
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

    func performTemporaryChatTap() {
        let preferredMode: TemporaryChatMemoryMode = appConfig.temporaryChatMemoryEnabled
            ? .enabled
            : .isolated
        let outcome = viewModel.performTemporaryChatTap(
            preferredMemoryMode: preferredMode,
            canEnable: isQuickActionAvailable(.temporaryChat)
        )

        let notice: ChatTransientNotice
        switch outcome {
        case .enabled(let memoryMode):
            isTemporaryChatEnabled = true
            temporaryChatMemoryMode = memoryMode
            notice = ChatTransientNotice(
                message: temporaryChatEnabledMessage(for: memoryMode),
                systemImage: ChatQuickAction.temporaryChat.systemImage(
                    isTemporaryChatEnabled: true,
                    memoryMode: memoryMode
                ),
                tint: .accentColor
            )
        case .memoryModeChanged(let memoryMode):
            appConfig.temporaryChatMemoryEnabled = memoryMode.isMemoryEnabled
            isTemporaryChatEnabled = true
            temporaryChatMemoryMode = memoryMode
            notice = ChatTransientNotice(
                message: temporaryChatMemoryModeChangedMessage(for: memoryMode),
                systemImage: ChatQuickAction.temporaryChat.systemImage(
                    isTemporaryChatEnabled: true,
                    memoryMode: memoryMode
                ),
                tint: .accentColor
            )
        case .disabled:
            isTemporaryChatEnabled = false
            notice = ChatTransientNotice(
                message: NSLocalizedString("临时对话已关闭", comment: "临时对话状态提示"),
                systemImage: "eye",
                tint: .secondary
            )
        case .unavailable:
            return
        }

        showChatTransientNotice(
            notice
        )
    }

    func refreshTemporaryChatState() {
        isTemporaryChatEnabled = viewModel.isTemporaryChatEnabled(for: viewModel.currentSession?.id)
        if let memoryMode = viewModel.temporaryChatMemoryMode(for: viewModel.currentSession?.id) {
            temporaryChatMemoryMode = memoryMode
        }
    }

    private func temporaryChatEnabledMessage(for memoryMode: TemporaryChatMemoryMode) -> String {
        switch memoryMode {
        case .enabled:
            return NSLocalizedString(
                "临时对话已开启，可使用记忆。2 秒内再点可切换模式。",
                comment: "开启允许记忆的临时对话提示"
            )
        case .isolated:
            return NSLocalizedString(
                "临时对话已开启，已隔离记忆。2 秒内再点可切换模式。",
                comment: "开启隔离记忆的临时对话提示"
            )
        }
    }

    private func temporaryChatMemoryModeChangedMessage(for memoryMode: TemporaryChatMemoryMode) -> String {
        switch memoryMode {
        case .enabled:
            return NSLocalizedString("临时对话已切换为可使用记忆", comment: "临时对话允许记忆提示")
        case .isolated:
            return NSLocalizedString("临时对话已切换为记忆隔离", comment: "临时对话隔离记忆提示")
        }
    }

    func isQuickActionAvailable(_ action: ChatQuickAction) -> Bool {
        if action == .browser {
            return viewModel.currentSession != nil
        } else if action == .localTerminal {
            return appConfig.localLinuxEnabled && viewModel.currentSession != nil
        }
        guard action == .temporaryChat else { return true }
        return TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: isTemporaryChatEnabled,
            hasConversationStarted: !viewModel.allMessagesForSession.isEmpty || continuationContext != nil
        )
    }

    func reloadChatQuickActions() {
        selectedChatQuickActions = ChatQuickActionSelection.decode(appConfig.chatQuickActionIDs)
        let toolbar = ChatQuickActionSelection.decodeToolbarActions(appConfig.chatToolbarActionIDs)
        chatToolbarActions = selectedChatQuickActions.filter(toolbar.contains)
        chatOverflowActions = selectedChatQuickActions.filter { !toolbar.contains($0) }
        if selectedChatQuickActions.count <= 1 {
            setChatQuickActionFolderPresented(false)
        }
    }

    @ViewBuilder
    func quickActionDestinationView(for action: ChatQuickAction) -> some View {
        switch action {
        case .temporaryChat, .modelPicker, .contextCompression:
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
        case .browser:
            BrowserAgentFeatureView(sessionID: viewModel.currentSession?.id)
        case .localTerminal:
            LocalLinuxTerminalView(initialJobID: localTerminalInitialJobID)
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
    let temporaryChatMemoryMode: TemporaryChatMemoryMode
    let isTemporaryChatToggleAvailable: Bool
    let isPresented: Bool
    let collapsedSize: CGFloat
    let expandedWidth: CGFloat
    let usesLiquidGlass: Bool
    let glassTintOpacity: Double
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
        let opacity = LiquidGlassTintSetting.normalized(glassTintOpacity)
        return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
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
        action.systemImage(
            isTemporaryChatEnabled: isTemporaryChatEnabled,
            memoryMode: temporaryChatMemoryMode
        )
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
