// ============================================================================
// ChatView.swift
// ============================================================================
// 聊天主界面 (iOS) - Telegram 风格
// - Telegram 风格的顶部导航栏（标题 + 副标题）
// - Telegram 风格的底部输入栏（圆角输入框 + 附件 + 发送按钮）
// - 支持壁纸背景、消息气泡
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色
private struct TelegramColors {
    // 导航栏颜色
    static let navBarText = Color.primary
    static let navBarSubtitle = Color.secondary
    
    // 输入栏颜色
    static let inputBackground = Color(uiColor: .systemBackground)
    static let inputFieldBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBorder = Color(uiColor: .separator)
    static let attachButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    static let sendButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    
    // 滚动按钮
    static let scrollButtonBackground = Color(uiColor: .systemBackground)
    static let scrollButtonShadow = Color.black.opacity(0.15)
}

struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var showScrollToBottom = false
    @State private var navigationDestination: ChatNavigationDestination?
    @State private var editingMessage: ChatMessage?
    @State private var messageInfo: MessageInfoPayload?
    @State private var showBranchOptions = false
    @State private var messageToBranch: ChatMessage?
    @State private var messageToDelete: ChatMessage?
    @State private var messageVersionToDelete: ChatMessage?
    @State private var fullErrorContent: FullErrorContentPayload?
    @State private var showModelPickerPanel = false
    @State private var showSessionPickerPanel = false
    @State private var editingSessionID: UUID?
    @State private var sessionDraftName: String = ""
    @State private var sessionToDelete: ChatSession?
    @State private var sessionInfo: SessionPickerInfoPayload?
    @State private var showGhostSessionAlert = false
    @State private var ghostSession: ChatSession?
    @FocusState private var composerFocused: Bool
    @AppStorage("chat.composer.draft") private var draftText: String = ""
    @Namespace private var modelPickerNamespace
    @Namespace private var sessionPickerNamespace
    
    private let scrollBottomAnchorID = "chat-scroll-bottom"
    private let navBarTitleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
    private let navBarSubtitleFont = UIFont.systemFont(ofSize: 12)
    private let navBarVerticalPadding: CGFloat = 8
    private let navBarPillVerticalPadding: CGFloat = 6
    private let navBarPillSpacing: CGFloat = 1
    private let navBarBlurFadeHeightRatio: CGFloat = 0.05
    private let modelPickerHeightRatio: CGFloat = 0.4
    private let modelPickerCornerRadius: CGFloat = 24
    private let modelPickerAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)
    private let modelPickerMorphID = "modelPickerMorph"
    private let sessionPickerHeightRatio: CGFloat = 0.6
    private let sessionPickerCornerRadius: CGFloat = 26
    private let sessionPickerMorphID = "sessionPickerMorph"
    private var navBarPillHeight: CGFloat {
        navBarTitleFont.lineHeight
            + navBarSubtitleFont.lineHeight
            + navBarPillSpacing
            + navBarPillVerticalPadding * 2
    }
    private var navBarHeight: CGFloat {
        navBarPillHeight + navBarVerticalPadding * 2
    }
    private var navBarIconSize: CGFloat {
        navBarPillHeight
    }
    private var isOverlayPanelPresented: Bool {
        showModelPickerPanel || showSessionPickerPanel
    }
    private var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    private var navBarGlassOverlayColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.2)
    }
    private var modelPickerPanelBaseTint: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.78)
    }
    private var displayMessages: [ChatMessage] {
        var representedToolCallIDs = Set<String>()
        for message in viewModel.messages {
            guard message.role == .tool else { continue }
            let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedContent.isEmpty,
                  let toolCalls = message.toolCalls,
                  !toolCalls.isEmpty else { continue }
            for call in toolCalls {
                representedToolCallIDs.insert(call.id)
            }
        }

        return viewModel.messages.filter { message in
            guard message.role == .tool else { return true }
            let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContent.isEmpty else { return true }
            guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return true }
            return toolCalls.allSatisfy { !representedToolCallIDs.contains($0.id) }
        }
    }
    
    var body: some View {
        let displayedMessages = displayMessages
        NavigationStack {
            ZStack {
                // Z-Index 0: 背景壁纸层（穿透安全区）
                telegramBackgroundLayer
                    .ignoresSafeArea()
                
                // Z-Index 1: 消息列表
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2, pinnedViews: []) {
                            // 顶部留白（为导航栏留出空间）
                            Color.clear.frame(height: 8)
                            
                            // 历史加载提示
                            historyBanner
                            
                            // 消息列表
                            ForEach(displayedMessages) { message in
                                ChatBubble(
                                    message: message,
                                    isReasoningExpanded: Binding(
                                        get: { viewModel.reasoningExpandedState[message.id, default: false] },
                                        set: { viewModel.reasoningExpandedState[message.id] = $0 }
                                    ),
                                    isToolCallsExpanded: Binding(
                                        get: { viewModel.toolCallsExpandedState[message.id, default: false] },
                                        set: { viewModel.toolCallsExpandedState[message.id] = $0 }
                                    ),
                                    enableMarkdown: viewModel.enableMarkdown,
                                    enableBackground: viewModel.enableBackground,
                                    enableLiquidGlass: isLiquidGlassEnabled
                                )
                                .id(message.id)
                                .contextMenu {
                                    contextMenu(for: message)
                                }
                                .onAppear {
                                    if message.id == displayedMessages.last?.id {
                                        showScrollToBottom = false
                                    }
                                }
                                .onDisappear {
                                    if message.id == displayedMessages.last?.id {
                                        showScrollToBottom = true
                                    }
                                }
                            }

                            if let activeRequest = toolPermissionCenter.activeRequest {
                                ToolPermissionBubble(
                                    request: activeRequest,
                                    enableBackground: viewModel.enableBackground,
                                    enableLiquidGlass: isLiquidGlassEnabled,
                                    onDecision: { decision in
                                        toolPermissionCenter.resolveActiveRequest(with: decision)
                                    }
                                )
                                .id(activeRequest.id)
                            }
                            
                            Color.clear
                                .frame(height: 8)
                                .id(scrollBottomAnchorID)
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            composerFocused = false
                        }
                    )
                    .onChange(of: viewModel.messages.count) { _, _ in
                        guard !viewModel.messages.isEmpty else { return }
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: toolPermissionCenter.activeRequest?.id) { _, newValue in
                        guard newValue != nil, !showScrollToBottom else { return }
                        scrollToBottom(proxy: proxy)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // Telegram 风格的滚动到底部按钮
                        if showScrollToBottom {
                            telegramScrollToBottomButton {
                                viewModel.resetLazyLoadState()
                                scrollToBottom(proxy: proxy)
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 80)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    // Telegram 风格：顶部导航栏
                    .safeAreaInset(edge: .top) {
                        telegramNavBar
                    }
                    // Telegram 风格：底部输入栏
                    .safeAreaInset(edge: .bottom) {
                        telegramInputBar
                    }
                    .overlay(alignment: .top) {
                        navBarFadeBlurOverlay
                    }
                    .allowsHitTesting(!isOverlayPanelPresented)
                }

                if showModelPickerPanel {
                    modelPickerOverlay
                }

                if showSessionPickerPanel {
                    sessionPickerOverlay
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationDestination(item: $navigationDestination) { destination in
                switch destination {
                case .sessions:
                    SessionListView()
                case .settings:
                    SettingsView()
                }
            }
            .sheet(item: $editingMessage) { message in
                NavigationStack {
                    EditMessageView(message: message) { updatedMessage in
                        viewModel.commitEditedMessage(updatedMessage)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $messageInfo) { info in
                MessageInfoSheet(payload: info)
            }
            .sheet(item: $fullErrorContent) { payload in
                FullErrorContentSheet(payload: payload)
            }
            .sheet(item: $sessionInfo) { info in
                SessionPickerInfoSheet(payload: info)
            }
            .confirmationDialog("创建分支选项", isPresented: $showBranchOptions, titleVisibility: .visible) {
                Button("仅复制消息历史") {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: false)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button("复制消息历史和提示词") {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: true)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button("取消", role: .cancel) {
                    messageToBranch = nil
                }
            } message: {
                if let message = messageToBranch, let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
                    Text(String(format: NSLocalizedString("将从第 %d 条消息处创建新的分支会话。", comment: ""), index + 1))
                }
            }
            .alert("确认删除消息", isPresented: Binding(
                get: { messageToDelete != nil },
                set: { if !$0 { messageToDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let message = messageToDelete {
                        viewModel.deleteMessage(message)
                    }
                    messageToDelete = nil
                }
                Button("取消", role: .cancel) {
                    messageToDelete = nil
                }
            } message: {
                Text(messageToDelete?.hasMultipleVersions == true
                     ? "删除后将无法恢复这条消息的所有版本。"
                     : "删除后无法恢复这条消息。")
            }
            .alert("确认删除当前版本", isPresented: Binding(
                get: { messageVersionToDelete != nil },
                set: { if !$0 { messageVersionToDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let message = messageVersionToDelete {
                        viewModel.deleteCurrentVersion(of: message)
                    }
                    messageVersionToDelete = nil
                }
                Button("取消", role: .cancel) {
                    messageVersionToDelete = nil
                }
            } message: {
                Text("删除后将无法恢复此版本的内容。")
            }
            .alert("确认删除会话", isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionToDelete = nil
                    }
                }
            )) {
                Button("删除", role: .destructive) {
                    if let session = sessionToDelete {
                        viewModel.deleteSessions([session])
                    }
                    sessionToDelete = nil
                }
                Button("取消", role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                Text("删除后所有消息也将被移除，操作不可恢复。")
            }
            .alert("发现幽灵会话", isPresented: $showGhostSessionAlert) {
                Button("删除幽灵", role: .destructive) {
                    if let session = ghostSession {
                        viewModel.deleteSessions([session])
                    }
                    ghostSession = nil
                }
                Button("稍后处理", role: .cancel) {
                    ghostSession = nil
                }
            } message: {
                Text("这个会话的消息文件已经丢失了，只剩下一个空壳在这里游荡。\n\n要帮它超度吗？")
            }
        }
    }
    
    // MARK: - Background
    
    /// Telegram 风格的背景层
    private var telegramBackgroundLayer: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.enableBackground,
                   let image = viewModel.currentBackgroundImageUIImage {
                    ZStack {
                        if viewModel.backgroundContentMode == "fit" {
                            Color.black
                        }
                        
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(
                                contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .clipped()
                            .blur(radius: viewModel.backgroundBlur)
                            .opacity(viewModel.backgroundOpacity)
                    }
                } else {
                    // Telegram 默认背景 - 浅色图案背景
                    TelegramDefaultBackground()
                }
            }
        }
    }

// MARK: - Telegram Style Components

    /// Telegram 风格导航栏
    @ViewBuilder
    private var telegramNavBar: some View {
        HStack(spacing: 12) {
            navBarSessionButton

            Spacer(minLength: 12)

            Button {
                toggleModelPickerPanel()
            } label: {
                navBarCenterPill
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Button {
                navigationDestination = .settings
            } label: {
                navBarIconLabel(systemName: "gearshape", accessibilityLabel: "设置")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, navBarVerticalPadding)
    }

    private var navBarSessionButton: some View {
        Button {
            toggleSessionPickerPanel()
        } label: {
            navBarSessionLabel
        }
        .buttonStyle(.plain)
    }

    private var navBarSessionLabel: some View {
        Image(systemName: "list.bullet")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(TelegramColors.navBarText)
            .frame(width: navBarIconSize, height: navBarIconSize)
            .background(
                sessionPickerButtonBackground
            )
            .overlay(
                Circle()
                    .stroke(showSessionPickerPanel ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
            )
            .contentShape(Circle())
            .accessibilityLabel("会话列表")
    }

    private func navBarIconLabel(systemName: String, accessibilityLabel: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(TelegramColors.navBarText)
            .frame(width: navBarIconSize, height: navBarIconSize)
            .background(
                navBarIconBackground
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Circle())
            .accessibilityLabel(accessibilityLabel)
    }

    private var navBarCenterPill: some View {
        VStack(spacing: navBarPillSpacing) {
            MarqueeText(
                content: viewModel.currentSession?.name ?? "新的对话",
                uiFont: navBarTitleFont
            )
            .foregroundColor(TelegramColors.navBarText)
            .allowsHitTesting(false)

            if viewModel.activatedModels.isEmpty {
                MarqueeText(content: "选择模型以开始", uiFont: navBarSubtitleFont)
                    .foregroundColor(TelegramColors.navBarSubtitle)
                    .allowsHitTesting(false)
            } else {
                MarqueeText(content: modelSubtitle, uiFont: navBarSubtitleFont)
                    .foregroundColor(TelegramColors.navBarSubtitle)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, navBarPillVerticalPadding)
        .frame(height: navBarPillHeight)
        .background(
            navBarPillBackground
        )
        .overlay(
            Capsule()
                .stroke(showModelPickerPanel ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
        )
        .overlay(alignment: .trailing) {
            Image(systemName: showModelPickerPanel ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(TelegramColors.navBarSubtitle)
                .padding(.trailing, 10)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private var navBarIconBackground: some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Circle())
                    .overlay(
                        Circle()
                            .fill(navBarGlassOverlayColor)
                    )
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(navBarGlassOverlayColor)
                    )
            }
        } else {
            Circle()
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var navBarPillBackground: some View {
        modelPickerMorphBackground(isExpanded: false, isSource: !showModelPickerPanel)
    }

    private var sessionPickerButtonBackground: some View {
        sessionPickerMorphBackground(isExpanded: false, isSource: !showSessionPickerPanel)
    }

    private var sessionPickerPanelBackground: some View {
        sessionPickerMorphBackground(isExpanded: true, isSource: showSessionPickerPanel)
    }

    @ViewBuilder
    private func sessionPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
        if isExpanded {
            ZStack {
                RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                    .fill(modelPickerPanelBaseTint)

                if isLiquidGlassEnabled {
                    if #available(iOS 26.0, *) {
                        RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                            .fill(Color.clear)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                                    .fill(navBarGlassOverlayColor)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                                    .fill(navBarGlassOverlayColor)
                            )
                    }
                } else {
                    RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .matchedGeometryEffect(id: sessionPickerMorphID, in: sessionPickerNamespace, isSource: isSource)
        } else {
            ZStack {
                if isLiquidGlassEnabled {
                    if #available(iOS 26.0, *) {
                        Circle()
                            .fill(Color.clear)
                            .glassEffect(.clear, in: Circle())
                            .overlay(
                                Circle()
                                    .fill(navBarGlassOverlayColor)
                            )
                    } else {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .fill(navBarGlassOverlayColor)
                            )
                    }
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                }
            }
            .matchedGeometryEffect(id: sessionPickerMorphID, in: sessionPickerNamespace, isSource: isSource)
        }
    }

    private var modelSubtitle: String {
        if let selectedModel = viewModel.selectedModel {
            return "\(selectedModel.model.displayName) · \(selectedModel.provider.name)"
        }
        return "选择模型"
    }

    private var navBarFadeBlurOverlay: some View {
        GeometryReader { proxy in
            let adaptiveHeight = proxy.size.height * navBarBlurFadeHeightRatio
            BlurView(style: .regular)
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.black, location: 0),
                            .init(color: Color.black.opacity(0.7), location: 0.35),
                            .init(color: Color.black.opacity(0), location: 1)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(maxWidth: .infinity)
                .frame(height: navBarHeight + adaptiveHeight)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
    }

    private func toggleModelPickerPanel() {
        withAnimation(modelPickerAnimation) {
            if showSessionPickerPanel {
                showSessionPickerPanel = false
            }
            showModelPickerPanel.toggle()
        }
    }

    private func dismissModelPickerPanel() {
        withAnimation(modelPickerAnimation) {
            showModelPickerPanel = false
        }
    }

    private func toggleSessionPickerPanel() {
        withAnimation(modelPickerAnimation) {
            if showModelPickerPanel {
                showModelPickerPanel = false
            }
            showSessionPickerPanel.toggle()
        }
    }

    private func dismissSessionPickerPanel() {
        withAnimation(modelPickerAnimation) {
            showSessionPickerPanel = false
        }
    }

    private var modelPickerOverlay: some View {
        GeometryReader { proxy in
            let panelHeight = proxy.size.height * modelPickerHeightRatio
            ZStack(alignment: .top) {
                Color.black.opacity(colorScheme == .dark ? 0.35 : 0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissModelPickerPanel()
                    }
                    .transition(.opacity)

                VStack(spacing: 12) {
                    modelPickerHeader

                    if viewModel.activatedModels.isEmpty {
                        modelPickerEmptyState
                    } else {
                        modelPickerList
                    }
                }
                .frame(width: proxy.size.width, height: panelHeight, alignment: .top)
                .background(modelPickerPanelBackground)
                .clipShape(RoundedRectangle(cornerRadius: modelPickerCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: modelPickerCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 10)
                .offset(y: navBarHeight + 6)
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.96, anchor: .top))
                )
            }
        }
    }

    private var modelPickerHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择模型")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                Text("切换当前对话的模型")
                    .font(.system(size: 12))
                    .foregroundColor(TelegramColors.navBarSubtitle)
            }

            Spacer()

            pickerHeaderActionButton(
                systemName: "xmark",
                accessibilityLabel: "关闭"
            ) {
                dismissModelPickerPanel()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var modelPickerEmptyState: some View {
        VStack(spacing: 8) {
            Text("暂无可用模型")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
            Text("请先在设置中启用模型")
                .font(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var modelPickerList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.activatedModels, id: \.id) { runnable in
                    modelPickerRow(runnable)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func modelPickerRow(_ runnable: RunnableModel) -> some View {
        let isSelected = runnable.id == viewModel.selectedModel?.id
        let baseFill = colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
        let selectedFill = colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)

        return Button {
            viewModel.setSelectedModel(runnable)
            dismissModelPickerPanel()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(runnable.model.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(TelegramColors.navBarText)
                    Text(runnable.provider.name)
                        .font(.system(size: 12))
                        .foregroundColor(TelegramColors.navBarSubtitle)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSelected ? TelegramColors.sendButtonColor : TelegramColors.navBarSubtitle.opacity(0.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? selectedFill : baseFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.35 : 0.15), lineWidth: isSelected ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modelPickerPanelBackground: some View {
        modelPickerMorphBackground(isExpanded: true, isSource: showModelPickerPanel)
    }

    @ViewBuilder
    private func modelPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
        let cornerRadius = isExpanded ? modelPickerCornerRadius : navBarPillHeight / 2

        ZStack {
            if isExpanded {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(modelPickerPanelBaseTint)
            }

            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .matchedGeometryEffect(id: modelPickerMorphID, in: modelPickerNamespace, isSource: isSource)
    }

    private var sessionPickerOverlay: some View {
        GeometryReader { proxy in
            let panelHeight = proxy.size.height * sessionPickerHeightRatio
            ZStack(alignment: .top) {
                Color.black.opacity(colorScheme == .dark ? 0.35 : 0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissSessionPickerPanel()
                    }
                    .transition(.opacity)

                VStack(spacing: 12) {
                    sessionPickerHeader

                    if viewModel.chatSessions.isEmpty {
                        sessionPickerEmptyState
                    } else {
                        sessionPickerList
                    }

                    sessionPickerFooter
                }
                .frame(width: proxy.size.width, height: panelHeight, alignment: .top)
                .background(sessionPickerPanelBackground)
                .clipShape(RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.2), radius: 22, x: 0, y: 12)
                .offset(y: navBarHeight + 6)
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.96, anchor: .top))
                )
            }
        }
    }

    private var sessionPickerHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("会话")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                Text("快速切换与管理")
                    .font(.system(size: 12))
                    .foregroundColor(TelegramColors.navBarSubtitle)
            }

            Spacer()

            HStack(spacing: 8) {
                pickerHeaderActionButton(
                    systemName: "plus",
                    accessibilityLabel: "开启新对话"
                ) {
                    viewModel.createNewSession()
                    editingSessionID = nil
                    sessionDraftName = ""
                    dismissSessionPickerPanel()
                }

                pickerHeaderActionButton(
                    systemName: "xmark",
                    accessibilityLabel: "关闭"
                ) {
                    dismissSessionPickerPanel()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var sessionPickerEmptyState: some View {
        VStack(spacing: 8) {
            Text("暂无会话")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
            Text("创建一个新对话开始吧")
                .font(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var sessionPickerList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.chatSessions) { session in
                    sessionPickerRow(session)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sessionPickerFooter: some View {
        Text(String(format: NSLocalizedString("共 %d 个会话", comment: ""), viewModel.chatSessions.count))
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(TelegramColors.navBarSubtitle)
            .padding(.bottom, 14)
    }

    private func pickerHeaderActionButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func sessionPickerRow(_ session: ChatSession) -> some View {
        let isCurrent = session.id == viewModel.currentSession?.id
        let isEditing = editingSessionID == session.id
        let baseFill = colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
        let selectedFill = colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)

        return SessionPickerRow(
            session: session,
            isCurrent: isCurrent,
            isEditing: isEditing,
            draftName: isEditing ? $sessionDraftName : .constant(session.name),
            onCommit: { newName in
                viewModel.updateSessionName(session, newName: newName)
                editingSessionID = nil
            },
            onSelect: {
                selectSessionFromPicker(session)
            },
            onRename: {
                editingSessionID = session.id
                sessionDraftName = session.name
            },
            onBranch: { copyHistory in
                let newSession = viewModel.branchSession(from: session, copyMessages: copyHistory)
                viewModel.setCurrentSession(newSession)
                dismissSessionPickerPanel()
            },
            onDeleteLastMessage: {
                viewModel.deleteLastMessage(for: session)
            },
            onDelete: {
                sessionToDelete = session
            },
            onCancelRename: {
                editingSessionID = nil
                sessionDraftName = session.name
            },
            onInfo: {
                sessionInfo = SessionPickerInfoPayload(
                    session: session,
                    messageCount: viewModel.messageCount(for: session),
                    isCurrent: isCurrent
                )
            }
        )
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? selectedFill : baseFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(isCurrent ? 0.3 : 0.15), lineWidth: isCurrent ? 0.8 : 0.5)
        )
    }

    private func selectSessionFromPicker(_ session: ChatSession) {
        if session.isTemporary {
            editingSessionID = nil
            viewModel.setCurrentSession(session)
            dismissSessionPickerPanel()
            return
        }

        let messageFile = Persistence.getChatsDirectory().appendingPathComponent("\(session.id.uuidString).json")

        if !FileManager.default.fileExists(atPath: messageFile.path) {
            ghostSession = session
            showGhostSessionAlert = true
        } else {
            editingSessionID = nil
            viewModel.setCurrentSession(session)
            dismissSessionPickerPanel()
        }
    }

    /// Telegram 风格输入栏
    @ViewBuilder
    private var telegramInputBar: some View {
        TelegramMessageComposer(
            text: Binding(
                get: { draftText },
                set: { newValue in
                    draftText = newValue
                    viewModel.userInput = newValue
                }
            ),
            isSending: viewModel.isSendingMessage,
            sendAction: {
                guard viewModel.canSendMessage else { return }
                viewModel.sendMessage()
                draftText = ""
            },
            stopAction: {
                viewModel.cancelSending()
            },
            focus: $composerFocused
        )
        .onAppear {
            viewModel.userInput = draftText
        }
    }
    
    /// Telegram 风格滚动到底部按钮
    @ViewBuilder
    private func telegramScrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(TelegramColors.scrollButtonBackground)
                    .frame(width: 40, height: 40)
                    .shadow(color: TelegramColors.scrollButtonShadow, radius: 4, x: 0, y: 2)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.attachButtonColor)
            }
        }
        .accessibilityLabel("滚动到底部")
    }
    
    /// Telegram 风格历史加载提示
    @ViewBuilder
    private var historyBanner: some View {
        let remainingCount = viewModel.allMessagesForSession.count - viewModel.messages.count
        if remainingCount > 0 && !viewModel.isHistoryFullyLoaded {
            let chunk = min(remainingCount, viewModel.historyLoadChunkSize)
            Button {
                withAnimation {
                    viewModel.loadMoreHistoryChunk()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 14))
                    Text(String(format: NSLocalizedString("加载更早的 %d 条消息", comment: ""), chunk))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(TelegramColors.attachButtonColor)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(
                    Capsule()
                        .fill(Color(uiColor: .systemBackground).opacity(0.9))
                        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func contextMenu(for message: ChatMessage) -> some View {
        // 有音频或图片附件的消息不显示编辑按钮
        let hasAttachments = message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
        
        if !hasAttachments {
            Button {
                editingMessage = message
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
        
        if viewModel.canRetry(message: message) {
            Button {
                viewModel.retryMessage(message)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
        }
        
        // 如果错误消息有完整内容（被截断），显示查看完整响应按钮
        if message.role == .error, let fullContent = message.fullErrorContent {
            Button {
                fullErrorContent = FullErrorContentPayload(content: fullContent)
            } label: {
                Label("查看完整响应", systemImage: "doc.text.magnifyingglass")
            }
        }
        
        Button {
            messageToBranch = message
            showBranchOptions = true
        } label: {
            Label("从此处创建分支", systemImage: "arrow.triangle.branch")
        }
        
        Divider()
        
        // 版本管理菜单项
        if message.hasMultipleVersions {
            Menu {
                ForEach(0..<message.getAllVersions().count, id: \.self) { index in
                    Button {
                        viewModel.switchToVersion(index, of: message)
                    } label: {
                        HStack {
                            Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                            if index == message.getCurrentVersionIndex() {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(
                    String(
                        format: NSLocalizedString("切换版本 (%d/%d)", comment: ""),
                        message.getCurrentVersionIndex() + 1,
                        message.getAllVersions().count
                    ),
                    systemImage: "clock.arrow.circlepath"
                )
            }
            
            if message.getAllVersions().count > 1 {
                Button(role: .destructive) {
                    messageVersionToDelete = message
                } label: {
                    Label("删除当前版本", systemImage: "trash")
                }
            }
            
            Divider()
        }
        
        Button(role: .destructive) {
            messageToDelete = message
        } label: {
            Label(message.hasMultipleVersions ? "删除所有版本" : "删除消息", systemImage: "trash.fill")
        }
        
        Divider()
        
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("复制内容", systemImage: "doc.on.doc")
        }
        
        if let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
            Button {
                messageInfo = MessageInfoPayload(
                    message: message,
                    displayIndex: index + 1,
                    totalCount: viewModel.allMessagesForSession.count
                )
            } label: {
                Label("查看消息信息", systemImage: "info.circle")
            }
        }
    }
}

// MARK: - Helpers

private extension ChatView {
    func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                action()
            }
        } else {
            action()
        }
    }
}

// MARK: - Telegram Default Background

private struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

/// Telegram 风格默认背景（浅色图案）
private struct TelegramDefaultBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 基础渐变背景
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.1, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.1, blue: 0.12)]
                        : [Color(red: 0.85, green: 0.9, blue: 0.92), Color(red: 0.88, green: 0.92, blue: 0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                // 图案覆盖层（模拟 Telegram 的微妙图案）
                TelegramPatternView()
                    .opacity(colorScheme == .dark ? 0.03 : 0.05)
            }
        }
        .ignoresSafeArea()
    }
}

/// Telegram 风格背景图案
private struct TelegramPatternView: View {
    var body: some View {
        Canvas { context, size in
            let patternSize: CGFloat = 60
            let iconSize: CGFloat = 16
            
            for row in stride(from: 0, to: size.height + patternSize, by: patternSize) {
                for col in stride(from: 0, to: size.width + patternSize, by: patternSize) {
                    let offset = Int(row / patternSize) % 2 == 0 ? 0 : patternSize / 2
                    let x = col + offset
                    let y = row
                    
                    // 随机选择不同的图标
                    let iconIndex = Int(x + y) % 4
                    let symbolName: String
                    switch iconIndex {
                    case 0: symbolName = "bubble.left.fill"
                    case 1: symbolName = "heart.fill"
                    case 2: symbolName = "star.fill"
                    default: symbolName = "paperplane.fill"
                    }
                    
                    if let symbol = context.resolveSymbol(id: symbolName) {
                        context.draw(symbol, at: CGPoint(x: x, y: y))
                    } else {
                        // 绘制简单的圆形作为后备
                        let rect = CGRect(x: x - iconSize/2, y: y - iconSize/2, width: iconSize, height: iconSize)
                        context.fill(Circle().path(in: rect), with: .color(.gray))
                    }
                }
            }
        } symbols: {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("bubble.left.fill")
            
            Image(systemName: "heart.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("heart.fill")
            
            Image(systemName: "star.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("star.fill")
            
            Image(systemName: "paperplane.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("paperplane.fill")
        }
    }
}

// MARK: - Telegram Message Composer

/// Telegram 风格的消息输入框
private struct TelegramMessageComposer: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showAudioRecorder = false
    @State private var showAudioImporter = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isExpandedComposer = false
    @State private var inputAvailableWidth: CGFloat = 0
    @State private var compactInputWidth: CGFloat = 0
    
    private let controlSize: CGFloat = 40
    private let expandedControlSize: CGFloat = 34
    private let compactInputHeight: CGFloat = 44
    private var expandedInputHeight: CGFloat {
        let rawHeight = UIScreen.main.bounds.height * 0.3
        return max(160, min(rawHeight, 360))
    }
    private let inputFont = UIFont.systemFont(ofSize: 16)
    private let textContainerInset: CGFloat = 8
    private let textHorizontalPadding: CGFloat = 10
    private let compactTextVerticalPadding: CGFloat = 4
    private let expandedTextVerticalPadding: CGFloat = 6
    private var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    private var composerCornerRadius: CGFloat {
        isExpandedComposer ? 18 : compactInputHeight / 2
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil {
                telegramAttachmentPreview
                    .padding(.horizontal, 16)
            }
            
            // 主输入栏
            HStack(alignment: .bottom, spacing: 12) {
                if !isExpandedComposer {
                    attachmentMenuButton(size: controlSize)
                }
                
                // 输入框容器
                HStack(alignment: .bottom, spacing: 8) {
                    inputEditor
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: controlSize)
                .background(glassRoundedBackground(cornerRadius: composerCornerRadius))
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: InputWidthKey.self, value: proxy.size.width)
                    }
                }
                .onPreferenceChange(InputWidthKey.self) { width in
                    if abs(width - inputAvailableWidth) > 0.5 {
                        inputAvailableWidth = width
                    }
                    if !isExpandedComposer, abs(width - compactInputWidth) > 0.5 {
                        compactInputWidth = width
                    }
                }
                
                // 麦克风 / 发送 / 停止按钮
                if !isExpandedComposer {
                    actionControlButton(size: controlSize)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)

        }
        .padding(.bottom, 6)
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            viewModel.addImageAttachment(image)
                        }
                    }
                }
                selectedPhotos = []
            }
        }
        .onChange(of: text) { _, newValue in
            handleAutoExpand(for: newValue)
        }
        .onChange(of: inputAvailableWidth) { _, _ in
            handleAutoExpand(for: text)
        }
        .onChange(of: focus.wrappedValue) { _, isFocused in
            if isFocused {
                handleAutoExpand(for: text)
            } else if isExpandedComposer {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpandedComposer = false
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraImagePicker(isPresented: $showCamera) { image in
                if let image {
                    viewModel.addImageAttachment(image)
                }
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(format: viewModel.audioRecordingFormat) { attachment in
                viewModel.setAudioAttachment(attachment)
            }
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importAudioAttachment(from: url)
            case .failure(let error):
                print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private func attachmentMenuButton(size: CGFloat) -> some View {
        Menu {
            Button {
                showImagePicker = true
            } label: {
                Label("选择图片", systemImage: "photo")
            }

            Button {
                showCamera = true
            } label: {
                Label("拍照", systemImage: "camera")
            }
            .disabled(!isCameraAvailable)

            Button {
                showAudioRecorder = true
            } label: {
                Label("录制语音", systemImage: "waveform")
            }

            Button {
                showAudioImporter = true
            } label: {
                Label("从录音备忘录上传", systemImage: "music.note.list")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: max(14, size * 0.45), weight: .semibold))
                .foregroundColor(TelegramColors.attachButtonColor)
                .frame(width: size, height: size)
                .background(glassCircleBackground)
        }
        .buttonStyle(.plain)
    }

    private func actionControlButton(size: CGFloat) -> some View {
        Button {
            if isSending {
                stopAction()
            } else if hasContent {
                sendAction()
            } else if viewModel.enableSpeechInput {
                showAudioRecorder = true
            } else {
                focus.wrappedValue = true
            }
        } label: {
            Image(systemName: actionIconName)
                .font(.system(size: max(14, size * 0.45), weight: .semibold))
                .foregroundColor(actionForegroundColor)
                .frame(width: size, height: size)
                .background(actionBackground)
        }
        .buttonStyle(.plain)
        .disabled(!isSending && hasContent && !viewModel.canSendMessage)
    }

    @ViewBuilder
    private var inputEditor: some View {
        let targetHeight = isExpandedComposer ? expandedInputHeight : compactInputHeight
        let verticalPadding = isExpandedComposer ? expandedTextVerticalPadding : compactTextVerticalPadding

        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: inputFont.pointSize))
                .focused(focus)
                .scrollContentBackground(.hidden)
                .scrollDisabled(!isExpandedComposer)
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, textHorizontalPadding)

            if text.isEmpty {
                Text("Message")
                    .font(.system(size: inputFont.pointSize))
                    .foregroundColor(.secondary)
                    .padding(.top, verticalPadding + textContainerInset)
                    .padding(.leading, textHorizontalPadding + textContainerInset)
            }
        }
        .frame(minHeight: targetHeight, maxHeight: targetHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)
    }

    private func handleAutoExpand(for newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if isExpandedComposer {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpandedComposer = false
                }
            }
            return
        }

        let hasExplicitNewline = newValue.contains("\n")
        var shouldExpand = hasExplicitNewline

        if !shouldExpand {
            let baseWidth = compactInputWidth > 0 ? compactInputWidth : inputAvailableWidth
            let availableWidth = baseWidth
                - textHorizontalPadding * 2
                - textContainerInset * 2
            if availableWidth > 0 {
                let boundingRect = (newValue as NSString).boundingRect(
                    with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: inputFont],
                    context: nil
                )
                let lineCount = max(1, Int(ceil(boundingRect.height / inputFont.lineHeight)))
                shouldExpand = lineCount > 1
            }
        }

        if shouldExpand {
            guard focus.wrappedValue else { return }
            guard !isExpandedComposer else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = true
            }
            focus.wrappedValue = true
        } else if isExpandedComposer {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = false
            }
        }
    }

    private struct InputWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
    
    /// Telegram 风格附件预览
    @ViewBuilder
    private var telegramAttachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .offset(x: 6, y: -6)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("语音消息")
                                .font(.system(size: 13, weight: .medium))
                            Text(audio.fileName)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            glassRoundedBackground(cornerRadius: 18)
        )
    }

    private var hasContent: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = viewModel.pendingAudioAttachment != nil || !viewModel.pendingImageAttachments.isEmpty
        return hasText || hasAttachments
    }

    private func importAudioAttachment(from url: URL) {
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = await AudioAttachment(
                    data: data,
                    mimeType: audioMimeType(for: url),
                    format: audioFormat(for: url),
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.setAudioAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private func audioMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return ext.isEmpty ? "audio/m4a" : "audio/\(ext)"
    }

    private func audioFormat(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? AudioRecordingFormat.aac.fileExtension : ext
    }
    
    private var actionIconName: String {
        if isSending {
            return "stop.fill"
        }
        if hasContent {
            return "arrow.up"
        }
        return viewModel.enableSpeechInput ? "mic.fill" : "arrow.up"
    }
    
    private var actionForegroundColor: Color {
        if isSending || hasContent {
            return .white
        }
        return TelegramColors.attachButtonColor
    }
    
    @ViewBuilder
    private var actionBackground: some View {
        if isSending {
            actionCircleBackground(fill: Color.red.opacity(0.85))
        } else if hasContent {
            let fillColor = viewModel.canSendMessage
                ? TelegramColors.sendButtonColor
                : Color.gray.opacity(0.3)
            actionCircleBackground(fill: fillColor)
        } else {
            glassCircleBackground
        }
    }
    
    @ViewBuilder
    private func actionCircleBackground(fill: Color) -> some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(fill)
                    .glassEffect(.clear, in: Circle())
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                Circle()
                    .fill(fill)
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        } else {
            Circle()
                .fill(fill)
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
        }
    }

    private var glassCircleBackground: some View {
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: Circle())
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        Circle()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }
    
    private var glassCapsuleBackground: some View {
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    Capsule()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: Capsule())
                        .overlay(
                            Capsule()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Capsule()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Capsule()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        Capsule()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }

    private func glassRoundedBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        shape
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }
    
    private var glassOverlayColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.2)
    }
    
    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }
    
    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}

// MARK: - Legacy Composer (kept for compatibility)

private struct MessageComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showAttachmentMenu = false
    @State private var showImagePicker = false
    @State private var showAudioRecorder = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil {
                attachmentPreviewBar
                    .padding(.horizontal, 12)
            }
            
            HStack(alignment: .center, spacing: 12) {
                // 加号按钮（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .confirmationDialog("添加附件", isPresented: $showAttachmentMenu) {
                        Button("选择图片") {
                            showImagePicker = true
                        }
                        Button("录制语音") {
                            showAudioRecorder = true
                        }
                    }
                } else {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .confirmationDialog("添加附件", isPresented: $showAttachmentMenu) {
                        Button("选择图片") {
                            showImagePicker = true
                        }
                        Button("录制语音") {
                            showAudioRecorder = true
                        }
                    }
                }
                
                // 输入框（拉长的药丸型）
                if #available(iOS 26.0, *) {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.clear, in: Capsule())
                } else {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .background(
                        Capsule()
                            .fill(Color(uiColor: .secondarySystemFill))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
                
                // 发送箭头（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .disabled(!viewModel.canSendMessage)
                } else {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!viewModel.canSendMessage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            viewModel.addImageAttachment(image)
                        }
                    }
                }
                selectedPhotos = []
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(format: viewModel.audioRecordingFormat) { attachment in
                viewModel.setAudioAttachment(attachment)
            }
        }
    }
    
    @ViewBuilder
    private var attachmentPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 16))
                            .foregroundStyle(.tint)
                        
                        Text(audio.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 80)
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Camera Image Picker

private struct CameraImagePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraImagePicker

        init(_ parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            parent.onImagePicked(image)
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Audio Recorder Sheet

private struct AudioRecorderSheet: View {
    let format: AudioRecordingFormat
    let onComplete: (AudioAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isRecording = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var timer: Timer?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                // 录音时长显示
                Text(formatDuration(recordingDuration))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(isRecording ? .red : .primary)
                
                // 录音按钮
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Color.red : Color.accentColor)
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(isRecording ? .white : (colorScheme == .dark ? .black : .white))
                    }
                }
                
                if isRecording {
                    Text("正在录音...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("点击开始录音")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .navigationTitle("录制语音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelRecording()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        finishRecording()
                    }
                    .disabled(recordingURL == nil || isRecording)
                }
            }
        }
        .onDisappear {
            cancelRecording()
        }
    }
    
    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")
            
            let settings: [String: Any]
            switch format {
            case .aac:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            @unknown default:
                // 默认使用 AAC 格式
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            }
            
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            recordingURL = url
            isRecording = true
            recordingDuration = 0
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                recordingDuration += 0.1
            }
        } catch {
            // 录音启动失败
        }
    }
    
    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        isRecording = false
    }
    
    private func cancelRecording() {
        stopRecording()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }
    
    private func finishRecording() {
        stopRecording()
        guard let url = recordingURL,
              let data = try? Data(contentsOf: url) else {
            dismiss()
            return
        }
        
        let attachment = AudioAttachment(
            data: data,
            mimeType: format.mimeType,
            format: format.fileExtension,
            fileName: url.lastPathComponent
        )
        
        try? FileManager.default.removeItem(at: url)
        onComplete(attachment)
        dismiss()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Session Picker

/// 会话信息弹窗的数据载体，用于隔离 UI 与业务模型
private struct SessionPickerInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

/// 会话信息弹窗，展示基础状态与唯一标识
private struct SessionPickerInfoSheet: View {
    let payload: SessionPickerInfoPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("会话概览") {
                    LabeledContent("名称") {
                        Text(payload.session.name)
                    }
                    LabeledContent("状态") {
                        Text(payload.isCurrent ? "当前会话" : "历史会话")
                            .foregroundStyle(payload.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent("消息数量") {
                        Text(String(format: NSLocalizedString("%d 条", comment: ""), payload.messageCount))
                    }
                }

                if let topic = payload.session.topicPrompt, !topic.isEmpty {
                    Section("主题提示") {
                        Text(topic)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let enhanced = payload.session.enhancedPrompt, !enhanced.isEmpty {
                    Section("增强提示词") {
                        Text(enhanced)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("唯一标识") {
                    Text(payload.session.id.uuidString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("会话信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct SessionPickerRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isEditing: Bool
    @Binding var draftName: String

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField("会话名称", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        commit()
                    }
                    .onAppear { focused = true }

                HStack {
                    Button("保存") {
                        commit()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("取消") {
                        onCancelRename()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .font(.headline)
                        if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.footnote.bold())
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("切换到此会话", systemImage: "checkmark.circle")
            }

            Button {
                onRename()
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button {
                onBranch(false)
            } label: {
                Label("创建提示词分支", systemImage: "arrow.branch")
            }

            Button {
                onBranch(true)
            } label: {
                Label("复制历史创建分支", systemImage: "arrow.triangle.branch")
            }

            Button {
                onDeleteLastMessage()
            } label: {
                Label("删除最后一条消息", systemImage: "delete.backward")
            }

            Button {
                onInfo()
            } label: {
                Label("查看会话信息", systemImage: "info.circle")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除会话", systemImage: "trash")
            }
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

// MARK: - Message Info

/// 用于承载消息信息弹窗的数据结构，避免直接暴露ChatMessage本身。
private struct MessageInfoPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let displayIndex: Int
    let totalCount: Int
}

/// 用于承载完整错误响应内容的数据结构
private struct FullErrorContentPayload: Identifiable {
    let id = UUID()
    let content: String
}

/// 完整错误响应内容弹窗
private struct FullErrorContentSheet: View {
    let payload: FullErrorContentPayload
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(payload.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("完整响应")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = payload.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}

/// 消息详情弹窗，展示消息的唯一标识与位置索引。
private struct MessageInfoSheet: View {
    let payload: MessageInfoPayload
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    LabeledContent("角色") {
                        Text(roleDescription(payload.message.role))
                    }
                    LabeledContent("列表位置") {
                        Text(
                            String(
                                format: NSLocalizedString("第 %d / %d 条", comment: ""),
                                payload.displayIndex,
                                payload.totalCount
                            )
                        )
                    }
                }
                
                Section("唯一标识") {
                    Text(payload.message.id.uuidString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("消息信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
    
    /// 将消息角色转换为易读的中文描述
        private func roleDescription(_ role: MessageRole) -> String {
            switch role {
            case .system:
                return "系统"
            case .user:
                return "用户"
            case .assistant:
                return "助手"
            case .tool:
                return "工具"
            case .error:
                return "错误"
            @unknown default:
                return "未知"
            }
        }
    }
