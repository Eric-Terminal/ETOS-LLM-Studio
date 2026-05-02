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
import Photos
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色
extension ChatView {
    
    /// Telegram 风格的背景层
    var telegramBackgroundLayer: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.enableBackground,
                   let image = viewModel.currentBackgroundImageBlurredUIImage {
                    ZStack {
                        if viewModel.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground)
                        }
                        
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(
                                contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .clipped()
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
    var telegramNavBar: some View {
        HStack(spacing: 12) {
            if isNativeNavigationEnabled {
                navBarBackButton
            } else {
                navBarSessionButton
            }

            Spacer(minLength: 12)

            Button {
                toggleModelPickerPanel()
            } label: {
                navBarCenterPill
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Button {
                navigationDestination = isNativeNavigationEnabled ? .preferenceSettings : .settings
            } label: {
                navBarIconLabel(systemName: "gearshape", accessibilityLabel: "设置")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, navBarVerticalPadding)
    }

    var navBarBackButton: some View {
        Button {
            dismiss()
        } label: {
            navBarIconLabel(systemName: "chevron.left", accessibilityLabel: "返回历史会话")
        }
        .buttonStyle(.plain)
    }

    var preferenceSettingsView: some View {
        ModelAdvancedSettingsView(
            aiTemperature: $viewModel.aiTemperature,
            aiTopP: $viewModel.aiTopP,
            globalSystemPromptEntries: $viewModel.globalSystemPromptEntries,
            selectedGlobalSystemPromptEntryID: $viewModel.selectedGlobalSystemPromptEntryID,
            maxChatHistory: $viewModel.maxChatHistory,
            lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
            enableStreaming: $viewModel.enableStreaming,
            enableResponseSpeedMetrics: $viewModel.enableResponseSpeedMetrics,
            enableOpenAIStreamIncludeUsage: $viewModel.enableOpenAIStreamIncludeUsage,
            enableAutoSessionNaming: $viewModel.enableAutoSessionNaming,
            enableReasoningSummary: $viewModel.enableReasoningSummary,
            currentSession: $viewModel.currentSession,
            includeSystemTimeInPrompt: $viewModel.includeSystemTimeInPrompt,
            systemTimeInjectionPosition: $viewModel.systemTimeInjectionPosition,
            enablePeriodicTimeLandmark: $viewModel.enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: $viewModel.periodicTimeLandmarkIntervalMinutes,
            addGlobalSystemPromptEntry: viewModel.addGlobalSystemPromptEntry,
            selectGlobalSystemPromptEntry: viewModel.selectGlobalSystemPromptEntry,
            updateSelectedGlobalSystemPromptContent: viewModel.updateSelectedGlobalSystemPromptContent,
            updateGlobalSystemPromptEntry: viewModel.updateGlobalSystemPromptEntry,
            deleteGlobalSystemPromptEntry: { viewModel.deleteGlobalSystemPromptEntry(id: $0) }
        )
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    navigationDestination = nil
                } label: {
                    Label(NSLocalizedString("返回对话", comment: ""), systemImage: "chevron.left")
                }
            }
        }
    }

    var navBarSessionButton: some View {
        Button {
            toggleSessionPickerPanel()
        } label: {
            navBarSessionLabel
        }
        .buttonStyle(.plain)
    }

    var navBarSessionLabel: some View {
        Image(systemName: "list.bullet")
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
            .accessibilityLabel(NSLocalizedString("会话列表", comment: ""))
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

            if viewModel.activatedModels.isEmpty {
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
        modelPickerMorphBackground(isExpanded: false, isSource: !showModelPickerPanel)
    }

    var sessionPickerButtonBackground: some View {
        sessionPickerMorphBackground(isExpanded: false, isSource: !showSessionPickerPanel)
    }

    @ViewBuilder
    var sessionPickerPanelBackground: some View {
        sessionPickerMorphBackground(isExpanded: true, isSource: showSessionPickerPanel)
    }

    var modelSubtitle: String {
        if let selectedModel = viewModel.selectedModel {
            return "\(selectedModel.model.displayName) · \(selectedModel.provider.name)"
        }
        return NSLocalizedString("选择模型", comment: "")
    }

    var navBarFadeBlurOverlay: some View {
        GeometryReader { proxy in
            let adaptiveHeight = min(
                navBarBlurFadeMaxHeight,
                max(navBarBlurFadeMinHeight, proxy.size.height * navBarBlurFadeHeightRatio)
            )
            BlurView(style: .regular)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black, location: 0),
                        .init(color: Color.black.opacity(0.88), location: 0.28),
                        .init(color: Color.black.opacity(0.22), location: 0.72),
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

    func toggleModelPickerPanel() {
        guard !usesBottomSheetPickerStyle else {
            showSessionPickerPanel = false
            showModelPickerPanel = false
            activeChatPickerSheet = .model
            return
        }
        withAnimation(modelPickerAnimation) {
            if showSessionPickerPanel {
                showSessionPickerPanel = false
            }
            showModelPickerPanel.toggle()
        }
    }

    func dismissModelPickerPanel() {
        if usesBottomSheetPickerStyle {
            activeChatPickerSheet = nil
            return
        }
        withAnimation(modelPickerAnimation) {
            showModelPickerPanel = false
        }
    }

    func toggleSessionPickerPanel() {
        guard !usesBottomSheetPickerStyle else {
            showModelPickerPanel = false
            showSessionPickerPanel = false
            activeChatPickerSheet = .session
            return
        }
        withAnimation(modelPickerAnimation) {
            if showModelPickerPanel {
                showModelPickerPanel = false
            }
            if showSessionPickerPanel {
                resetSessionPickerSearchState()
            }
            showSessionPickerPanel.toggle()
        }
    }

    func dismissSessionPickerPanel() {
        if usesBottomSheetPickerStyle {
            activeChatPickerSheet = nil
            resetSessionPickerSearchState()
            return
        }
        withAnimation(modelPickerAnimation) {
            showSessionPickerPanel = false
            resetSessionPickerSearchState()
        }
    }

    func resetSessionPickerSearchState() {
        sessionPickerPendingSearchWorkItem?.cancel()
        sessionPickerPendingSearchWorkItem = nil
        sessionPickerSearchText = ""
        sessionPickerSearchHits = [:]
        isSessionPickerSearching = false
        showSessionPickerSearchInput = false
        sessionPickerSearchFocused = false
        sessionPickerSearchResultPageIndex = 0
    }

    func handleChatPickerSheetDismissed() {
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

    var nativeModelPickerSheet: some View {
        NavigationStack {
            List {
                if viewModel.activatedModels.isEmpty {
                    VStack(spacing: 6) {
                        Text(NSLocalizedString("暂无可用模型", comment: ""))
                            .etFont(.headline)
                        Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
                } else {
                    Section {
                        ForEach(viewModel.activatedModels, id: \.id) { runnable in
                            Button {
                                viewModel.setSelectedModel(runnable)
                                dismissModelPickerPanel()
                            } label: {
                                MarqueeTitleSubtitleSelectionRow(
                                    title: runnable.model.displayName,
                                    subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                                    isSelected: runnable.id == viewModel.selectedModel?.id,
                                    subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular)
                                )
                            }
                        }
                    } footer: {
                        Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("选择模型", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismissModelPickerPanel()
                    }
                }
            }
        }
    }

    var nativeSessionPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                nativeSessionPickerTopBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                Divider()

                sessionPickerList(
                    queryActive: nativeSessionPickerQueryActive,
                    isSearching: isSessionPickerSearching,
                    includesSearchInput: false
                )

                Divider()

                sessionPickerFooter(
                    queryActive: nativeSessionPickerQueryActive,
                    displayedCount: nativeSessionPickerDisplayedCount,
                    isSearching: isSessionPickerSearching
                )
                .padding(.top, 10)
            }
            .navigationTitle(NSLocalizedString("会话", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismissSessionPickerPanel()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.createNewSession()
                        editingSessionID = nil
                        sessionDraftName = ""
                        dismissSessionPickerPanel()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("开启新对话", comment: ""))
                }
            }
        }
        .onAppear {
            showSessionPickerSearchInput = false
            normalizeSessionPickerPageIndex()
            normalizeSessionPickerSearchResultPageIndex()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: sessionPickerSearchText) { _, newValue in
            sessionPickerSearchResultPageIndex = 0
            scheduleSessionPickerSearch(for: newValue)
        }
        .onChange(of: viewModel.chatSessionListVersion) { _, _ in
            normalizeSessionPickerPageIndex()
            normalizeSessionPickerSearchResultPageIndex()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.allMessageIdentityVersion) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onDisappear {
            sessionPickerPendingSearchWorkItem?.cancel()
            sessionPickerPendingSearchWorkItem = nil
        }
    }

    var nativeSessionPickerTopBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nativeSessionPickerSubtitle)
                .etFont(.footnote)
                .foregroundStyle(.secondary)

            sessionPickerSearchInput
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var nativeSessionPickerQueryActive: Bool {
        !SessionHistorySearchSupport.normalizedQuery(sessionPickerSearchText).isEmpty
    }

    var nativeSessionPickerDisplayedCount: Int {
        nativeSessionPickerQueryActive ? totalSessionPickerSearchResultCount : totalSessionPickerCount
    }

    var nativeSessionPickerSubtitle: String {
        if nativeSessionPickerQueryActive {
            if isSessionPickerSearching {
                return NSLocalizedString("正在搜索历史会话…", comment: "")
            }
            return String(
                format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""),
                nativeSessionPickerDisplayedCount,
                sessionPickerSearchHits.count
            )
        }
        return NSLocalizedString("快速切换与管理", comment: "")
    }

    var modelPickerOverlay: some View {
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

    var modelPickerHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("选择模型", comment: ""))
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                    .etFont(.system(size: 12))
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

    var modelPickerEmptyState: some View {
        VStack(spacing: 8) {
            Text(NSLocalizedString("暂无可用模型", comment: ""))
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
            Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                .etFont(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    var modelPickerList: some View {
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

    func modelPickerRow(_ runnable: RunnableModel) -> some View {
        let isSelected = runnable.id == viewModel.selectedModel?.id
        let baseFill = colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.05)
        let selectedFill = colorScheme == .dark ? Color.black.opacity(0.36) : Color.black.opacity(0.08)
        let borderOpacitySelected: Double = colorScheme == .dark ? 0.18 : 0.35
        let borderOpacityUnselected: Double = colorScheme == .dark ? 0.1 : 0.15

        return Button {
            viewModel.setSelectedModel(runnable)
            dismissModelPickerPanel()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                MarqueeTitleSubtitleLabel(
                    title: runnable.model.displayName,
                    subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                    titleUIFont: .systemFont(ofSize: 15, weight: .semibold),
                    subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    subtitleColor: TelegramColors.navBarSubtitle
                )
                .foregroundColor(TelegramColors.navBarText)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSelected ? TelegramColors.sendButtonColor : TelegramColors.navBarSubtitle.opacity(0.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                Group {
                    if isLiquidGlassEnabled {
                        if #available(iOS 26.0, *) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.clear)
                                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(navBarGlassOverlayColor)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(navBarGlassOverlayColor)
                                )
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? selectedFill : baseFill)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? borderOpacitySelected : borderOpacityUnselected), lineWidth: isSelected ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var modelPickerPanelBackground: some View {
        modelPickerMorphBackground(isExpanded: true, isSource: showModelPickerPanel)
    }

    @ViewBuilder
    func modelPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
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

    @ViewBuilder
    func sessionPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
        let cornerRadius = isExpanded ? sessionPickerCornerRadius : navBarIconSize / 2

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
        .matchedGeometryEffect(id: sessionPickerMorphID, in: sessionPickerNamespace, isSource: isSource)
    }
}
