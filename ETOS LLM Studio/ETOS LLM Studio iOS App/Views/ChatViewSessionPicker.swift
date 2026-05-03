// ============================================================================
// ChatViewSessionPicker.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的会话选择器、会话搜索、分页和跳转逻辑。
// ============================================================================

import Foundation
import SwiftUI
import Shared

extension ChatView {
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

    var sessionPickerOverlay: some View {
        let normalizedQuery = SessionHistorySearchSupport.normalizedQuery(sessionPickerSearchText)
        let queryActive = !normalizedQuery.isEmpty
        let displayedSessionCount = queryActive ? totalSessionPickerSearchResultCount : totalSessionPickerCount

        return GeometryReader { proxy in
            let panelHeight = proxy.size.height * sessionPickerHeightRatio
            ZStack(alignment: .top) {
                Color.black.opacity(colorScheme == .dark ? 0.35 : 0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissSessionPickerPanel()
                    }
                    .transition(.opacity)

                VStack(spacing: 12) {
                    sessionPickerHeader(
                        queryActive: queryActive,
                        displayedCount: displayedSessionCount,
                        isSearching: isSessionPickerSearching
                    )

                    sessionPickerList(
                        queryActive: queryActive,
                        isSearching: isSessionPickerSearching
                    )

                    sessionPickerFooter(
                        queryActive: queryActive,
                        displayedCount: displayedSessionCount,
                        isSearching: isSessionPickerSearching
                    )
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
        .onAppear {
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

    func sessionPickerHeader(queryActive: Bool, displayedCount: Int, isSearching: Bool) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("会话", comment: ""))
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                if queryActive {
                    Text(
                        isSearching
                        ? NSLocalizedString("正在搜索历史会话…", comment: "")
                        : String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), displayedCount, sessionPickerSearchHits.count)
                    )
                    .etFont(.system(size: 12))
                    .foregroundColor(TelegramColors.navBarSubtitle)
                } else {
                    Text(NSLocalizedString("快速切换与管理", comment: ""))
                        .etFont(.system(size: 12))
                        .foregroundColor(TelegramColors.navBarSubtitle)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                pickerHeaderActionButton(
                    systemName: "magnifyingglass",
                    accessibilityLabel: "搜索会话"
                ) {
                    showSessionPickerSearchInput = true
                    DispatchQueue.main.async {
                        sessionPickerSearchFocused = true
                    }
                }

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

    var sessionPickerSearchInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(NSLocalizedString("搜索会话标题或消息", comment: ""), text: $sessionPickerSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($sessionPickerSearchFocused)
            if !sessionPickerSearchText.isEmpty {
                Button {
                    sessionPickerSearchText = ""
                    sessionPickerSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Group {
                if isLiquidGlassEnabled {
                    if #available(iOS 26.0, *) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.clear)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(navBarGlassOverlayColor)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(navBarGlassOverlayColor)
                            )
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06))
                }
            }
        )
    }

    var sessionPickerSearchingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(NSLocalizedString("正在搜索历史会话…", comment: ""))
                .etFont(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 28)
    }

    func sessionPickerEmptyState(queryActive: Bool) -> some View {
        VStack(spacing: 8) {
            Text(queryActive ? NSLocalizedString("未找到匹配的搜索结果", comment: "") : NSLocalizedString("暂无会话", comment: ""))
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
            Text(queryActive ? NSLocalizedString("换个关键词试试看", comment: "") : NSLocalizedString("创建一个新对话开始吧", comment: ""))
                .etFont(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 28)
    }

    func sessionPickerList(
        queryActive: Bool,
        isSearching: Bool,
        includesSearchInput: Bool = true
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if includesSearchInput && showSessionPickerSearchInput {
                    sessionPickerSearchInput
                        .id("session-picker-search-input")
                }

                if queryActive && isSearching {
                    sessionPickerSearchingState
                } else if queryActive && totalSessionPickerSearchResultCount == 0 {
                    sessionPickerEmptyState(queryActive: true)
                } else if !queryActive && pagedSessionPickerSessions.isEmpty {
                    sessionPickerEmptyState(queryActive: false)
                } else {
                    if queryActive {
                        ForEach(pagedSessionPickerSearchResults) { result in
                            sessionPickerSearchResultRow(result)
                        }
                    } else {
                        ForEach(pagedSessionPickerSessions) { session in
                            sessionPickerRow(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func sessionPickerFooter(queryActive: Bool, displayedCount: Int, isSearching: Bool) -> some View {
        Group {
            if shouldShowSessionPickerPaginationBar(queryActive: queryActive) {
                HStack(spacing: 12) {
                    sessionPickerFooterButton(
                        systemName: "chevron.left",
                        accessibilityLabel: NSLocalizedString("上一页", comment: "Session picker previous page"),
                        isEnabled: canGoToPreviousActiveSessionPickerPage(queryActive: queryActive)
                    ) {
                        goToPreviousActiveSessionPickerPage(queryActive: queryActive)
                    }

                    Text(activeSessionPickerPaginationSummaryText(queryActive: queryActive))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.center)
                        .etFont(.system(size: 12, weight: .medium))
                        .foregroundColor(TelegramColors.navBarSubtitle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(sessionPickerFooterSummaryBackground)

                    sessionPickerFooterButton(
                        systemName: "chevron.right",
                        accessibilityLabel: NSLocalizedString("下一页", comment: "Session picker next page"),
                        isEnabled: canGoToNextActiveSessionPickerPage(queryActive: queryActive)
                    ) {
                        goToNextActiveSessionPickerPage(queryActive: queryActive)
                    }
                }
            } else {
                Text(
                    queryActive
                    ? (isSearching ? NSLocalizedString("正在搜索…", comment: "") : String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), displayedCount, sessionPickerSearchHits.count))
                    : String(format: NSLocalizedString("共 %d 个会话", comment: ""), viewModel.chatSessions.count)
                )
                .etFont(.system(size: 12, weight: .medium))
                .foregroundColor(TelegramColors.navBarSubtitle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    func sessionPickerFooterButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(isEnabled ? TelegramColors.sendButtonColor : TelegramColors.navBarSubtitle.opacity(0.45))
                .frame(width: 32, height: 32)
                .background(sessionPickerFooterButtonBackground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(accessibilityLabel, comment: "会话选择器按钮无障碍标签"))
    }

    @ViewBuilder
    var sessionPickerFooterButtonBackground: some View {
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
                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
        }
    }

    @ViewBuilder
    var sessionPickerFooterSummaryBackground: some View {
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
                .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06))
        }
    }

    func normalizeSessionPickerPageIndex() {
        let maxIndex = max(totalSessionPickerPages - 1, 0)
        if sessionPickerPageIndex > maxIndex {
            sessionPickerPageIndex = maxIndex
        } else if sessionPickerPageIndex < 0 {
            sessionPickerPageIndex = 0
        }
    }

    func normalizeSessionPickerSearchResultPageIndex() {
        let maxIndex = max(totalSessionPickerSearchResultPages - 1, 0)
        if sessionPickerSearchResultPageIndex > maxIndex {
            sessionPickerSearchResultPageIndex = maxIndex
        } else if sessionPickerSearchResultPageIndex < 0 {
            sessionPickerSearchResultPageIndex = 0
        }
    }

    func shouldShowSessionPickerPaginationBar(queryActive: Bool) -> Bool {
        queryActive ? shouldShowSessionPickerSearchPagination : shouldShowSessionPickerPagination
    }

    func canGoToPreviousActiveSessionPickerPage(queryActive: Bool) -> Bool {
        queryActive ? canGoToPreviousSessionPickerSearchResultPage : canGoToPreviousSessionPickerPage
    }

    func canGoToNextActiveSessionPickerPage(queryActive: Bool) -> Bool {
        queryActive ? canGoToNextSessionPickerSearchResultPage : canGoToNextSessionPickerPage
    }

    func activeSessionPickerPaginationSummaryText(queryActive: Bool) -> String {
        queryActive ? sessionPickerSearchPaginationSummaryText : sessionPickerPaginationSummaryText
    }

    func goToPreviousActiveSessionPickerPage(queryActive: Bool) {
        if queryActive {
            guard canGoToPreviousSessionPickerSearchResultPage else { return }
            sessionPickerSearchResultPageIndex -= 1
            return
        }
        guard canGoToPreviousSessionPickerPage else { return }
        sessionPickerPageIndex -= 1
    }

    func goToNextActiveSessionPickerPage(queryActive: Bool) {
        if queryActive {
            guard canGoToNextSessionPickerSearchResultPage else { return }
            sessionPickerSearchResultPageIndex += 1
            return
        }
        guard canGoToNextSessionPickerPage else { return }
        sessionPickerPageIndex += 1
    }

    func scheduleSessionPickerSearch(for query: String) {
        sessionPickerPendingSearchWorkItem?.cancel()
        sessionPickerPendingSearchWorkItem = nil

        let normalized = SessionHistorySearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else {
            sessionPickerSearchHits = [:]
            isSessionPickerSearching = false
            sessionPickerSearchResultPageIndex = 0
            return
        }

        isSessionPickerSearching = true
        sessionPickerLatestSearchToken += 1
        let searchToken = sessionPickerLatestSearchToken
        let sessionsSnapshot = viewModel.chatSessions
        let currentSessionIDSnapshot = viewModel.currentSession?.id
        let currentMessagesSnapshot = viewModel.allMessagesForSession
        let querySnapshot = query

        let workItem = DispatchWorkItem {
            let hits = SessionHistorySearchSupport.searchHits(
                sessions: sessionsSnapshot,
                query: querySnapshot,
                currentSessionID: currentSessionIDSnapshot,
                currentSessionMessages: currentMessagesSnapshot,
                messageLoader: { sessionID in
                    Persistence.loadMessages(for: sessionID)
                }
            )
            DispatchQueue.main.async {
                guard searchToken == sessionPickerLatestSearchToken else { return }
                sessionPickerSearchHits = hits
                normalizeSessionPickerSearchResultPageIndex()
                isSessionPickerSearching = false
                sessionPickerPendingSearchWorkItem = nil
            }
        }

        sessionPickerPendingSearchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func pickerHeaderActionButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
                .frame(width: 32, height: 32)
                .background(
                    Group {
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
                                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    func sessionPickerRow(_ session: ChatSession) -> some View {
        let isCurrent = session.id == viewModel.currentSession?.id
        let isEditing = editingSessionID == session.id
        let selectedFill = Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.12)

        return SessionPickerRow(
            session: session,
            isCurrent: isCurrent,
            isRunning: viewModel.runningSessionIDs.contains(session.id),
            isEditing: isEditing,
            draftName: isEditing ? $sessionDraftName : .constant(session.name),
            searchSummary: nil,
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
            },
            onExport: { format, includeReasoning in
                exportSession(session, format: format, includeReasoning: includeReasoning)
            }
        )
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? selectedFill : Color.clear)
        )
    }

    func sessionPickerSearchResultRow(_ result: SessionHistorySearchResult) -> some View {
        let isCurrent = result.sessionID == viewModel.currentSession?.id
        let selectedFill = Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.12)

        return Button {
            if let session = viewModel.chatSessions.first(where: { $0.id == result.sessionID }) {
                selectSessionFromPicker(session, messageOrdinal: result.messageOrdinal)
            }
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: searchResultTitle(for: result),
                subtitle: result.match.preview,
                isSelected: isCurrent,
                titleUIFont: .systemFont(ofSize: 15, weight: .semibold),
                subtitleUIFont: .systemFont(ofSize: 12)
            )
            .foregroundColor(TelegramColors.navBarText)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? selectedFill : Color.clear)
        )
    }

    func sourceLabel(for source: SessionHistorySearchHitSource) -> String {
        switch source {
        case .sessionName:
            return NSLocalizedString("标题", comment: "")
        case .topicPrompt:
            return NSLocalizedString("主题提示", comment: "")
        case .enhancedPrompt:
            return NSLocalizedString("增强提示词", comment: "")
        case .userMessage:
            return NSLocalizedString("用户消息", comment: "")
        case .assistantMessage:
            return NSLocalizedString("助手消息", comment: "")
        case .systemMessage:
            return NSLocalizedString("系统消息", comment: "")
        case .toolMessage:
            return NSLocalizedString("工具消息", comment: "")
        case .errorMessage:
            return NSLocalizedString("错误消息", comment: "")
        }
    }

    func searchResultTitle(for result: SessionHistorySearchResult) -> String {
        if let messageOrdinal = result.messageOrdinal {
            return String(format: NSLocalizedString("“%@” 第%d条", comment: ""), result.sessionName, messageOrdinal)
        }
        return String(format: NSLocalizedString("“%@” %@", comment: ""), result.sessionName, sourceLabel(for: result.match.source))
    }

    func selectSessionFromPicker(_ session: ChatSession, messageOrdinal: Int? = nil) {
        if session.isTemporary {
            editingSessionID = nil
            if let messageOrdinal {
                viewModel.requestMessageJump(sessionID: session.id, messageOrdinal: messageOrdinal)
            } else {
                viewModel.clearPendingMessageJumpTarget()
            }
            viewModel.setCurrentSession(session)
            dismissSessionPickerPanel()
            return
        }

        if !Persistence.sessionDataExists(sessionID: session.id) {
            ghostSession = session
            showGhostSessionAlert = true
        } else {
            editingSessionID = nil
            if let messageOrdinal {
                viewModel.requestMessageJump(sessionID: session.id, messageOrdinal: messageOrdinal)
            } else {
                viewModel.clearPendingMessageJumpTarget()
            }
            viewModel.setCurrentSession(session)
            dismissSessionPickerPanel()
        }
    }
}
