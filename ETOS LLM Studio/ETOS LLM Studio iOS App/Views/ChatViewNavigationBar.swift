// ============================================================================
// ChatViewNavigationBar.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 顶部 Telegram 风格导航栏与选择器开关逻辑。
// ============================================================================

import SwiftUI
import Shared

extension ChatView {
    /// Telegram 风格导航栏
    @ViewBuilder
    var telegramNavBar: some View {
        HStack(spacing: 12) {
            navBarSessionButton

            Spacer(minLength: 12)

            Button {
                presentModelPickerSheet()
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

    var navBarSessionButton: some View {
        Button {
            presentSessionPicker()
        } label: {
            navBarSessionLabel
        }
        .buttonStyle(.plain)
    }

    var navBarSessionLabel: some View {
        Image(systemName: navBarSessionIconName)
            .etFont(.system(size: 17, weight: .semibold))
            .foregroundColor(TelegramColors.navBarText)
            .frame(width: navBarIconSize, height: navBarIconSize)
            .background(
                sessionPickerButtonBackground
            )
            .overlay(
                Circle()
                    .stroke(isSessionPickerPresented ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
            )
            .contentShape(Circle())
            .accessibilityLabel(navBarSessionAccessibilityLabel)
    }

    func navBarIconLabel(systemName: String, accessibilityLabel: String) -> some View {
        Image(systemName: systemName)
            .etFont(.system(size: 17, weight: .semibold))
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
            .accessibilityLabel(NSLocalizedString(accessibilityLabel, comment: "导航栏图标无障碍标签"))
    }

    var navBarCenterPill: some View {
        VStack(spacing: navBarPillSpacing) {
            MarqueeText(
                content: viewModel.currentSession?.name ?? NSLocalizedString("新的对话", comment: ""),
                uiFont: navBarTitleFont
            )
            .foregroundColor(TelegramColors.navBarText)
            .allowsHitTesting(false)

            if viewModel.activatedConversationModels.isEmpty {
                MarqueeText(content: NSLocalizedString("选择模型以开始", comment: ""), uiFont: navBarSubtitleFont)
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
                .stroke(isModelPickerPresented ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
        )
        .overlay(alignment: .trailing) {
            Image(systemName: isModelPickerPresented ? "chevron.up" : "chevron.down")
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundColor(TelegramColors.navBarSubtitle)
                .padding(.trailing, 10)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    var navBarIconBackground: some View {
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
    var navBarPillBackground: some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Capsule()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Capsule())
                    .overlay(
                        Capsule()
                            .fill(navBarGlassOverlayColor)
                    )
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(navBarGlassOverlayColor)
                    )
            }
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    var sessionPickerButtonBackground: some View {
        navBarIconBackground
    }

    var modelSubtitle: String {
        if let selectedModel = viewModel.selectedModel {
            return "\(selectedModel.model.displayName) · \(selectedModel.provider.name)"
        }
        return NSLocalizedString("选择模型", comment: "")
    }

    var navBarSessionIconName: String {
        guard usesLandscapeSessionSidebar else { return "list.bullet" }
        return isLandscapeSessionSidebarPresented ? "sidebar.right" : "sidebar.left"
    }

    var navBarSessionAccessibilityLabel: String {
        guard usesLandscapeSessionSidebar else {
            return NSLocalizedString("会话列表", comment: "")
        }
        return isLandscapeSessionSidebarPresented
            ? NSLocalizedString("隐藏会话列表", comment: "")
            : NSLocalizedString("显示会话列表", comment: "")
    }

    func presentModelPickerSheet() {
        activeChatPickerSheet = .model
    }

    func dismissModelPickerSheet() {
        activeChatPickerSheet = nil
    }

    func presentSessionPicker() {
        guard !usesLandscapeSessionSidebar else {
            activeChatPickerSheet = nil
            withAnimation(chatPickerAnimation) {
                isLandscapeSessionSidebarPresented.toggle()
                if !isLandscapeSessionSidebarPresented {
                    resetSessionPickerSearchState()
                }
            }
            return
        }
        activeChatPickerSheet = .session
    }

    func dismissSessionPicker() {
        if usesLandscapeSessionSidebar {
            withAnimation(chatPickerAnimation) {
                isLandscapeSessionSidebarPresented = false
                resetSessionPickerSearchState()
            }
            return
        }
        activeChatPickerSheet = nil
        resetSessionPickerSearchState()
    }

    func resetSessionPickerSearchState() {
        sessionPickerPendingSearchWorkItem?.cancel()
        sessionPickerPendingSearchWorkItem = nil
        sessionPickerSearchText = ""
        sessionPickerSearchHits = [:]
        isSessionPickerSearching = false
        sessionPickerSearchFocused = false
        loadedSessionPickerSearchResults = []
        isLoadingMoreSessionPickerSessions = false
        isLoadingMoreSessionPickerSearchResults = false
    }

    func handleChatPickerSheetDismissed() {
        resetSessionPickerSearchState()
    }

    func handleChatLayoutChange(isLandscape: Bool) {
        guard isChatLayoutLandscape != isLandscape else { return }
        isChatLayoutLandscape = isLandscape
        if isLandscape {
            if activeChatPickerSheet == .session {
                activeChatPickerSheet = nil
            }
            isLandscapeSessionSidebarPresented = true
            return
        }
        isLandscapeSessionSidebarPresented = false
        resetSessionPickerSearchState()
    }

    @ViewBuilder
    func chatPickerSheet(for sheet: ChatPickerSheet) -> some View {
        switch sheet {
        case .session:
            nativeSessionPickerSheet
        case .model:
            nativeModelPickerSheet
        }
    }
}
