// ============================================================================
// ChatViewSessionPicker.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的会话选择器、会话搜索、无限滚动和跳转逻辑。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

extension ChatView {
    var nativeSessionPickerSheet: some View {
        applySessionPickerLifecycle(
            to: NavigationStack {
                if activeChatPickerDetent == .large {
                    expandedSessionManagerContent
                } else {
                    nativeSessionPickerContent(
                        showsCloseButton: true,
                        showsSearchInput: false,
                        showsFooter: false
                    )
                }
            }
        )
    }

    var expandedSessionManagerContent: some View {
        SessionListView(createConversationAction: createConversationFromExpandedSessionManager)
            .environmentObject(viewModel)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        openSettingsFromSessionPicker()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(NSLocalizedString("设置", comment: "会话选择器设置入口"))
                }
            }
    }

    func createConversationFromExpandedSessionManager() {
        viewModel.createNewSession()
        dismissSessionPicker()
    }

    var landscapeSessionSidebar: some View {
        applySessionPickerLifecycle(
            to: nativeSessionPickerContent(
                showsCloseButton: false,
                showsTopDivider: false,
                showsFooterDivider: false,
                showsInlineCreateButton: true,
                showsFooter: false
            )
        )
    }

    func nativeSessionPickerContent(
        showsCloseButton: Bool,
        showsTopDivider: Bool = true,
        showsFooterDivider: Bool = true,
        showsInlineCreateButton: Bool = false,
        showsSearchInput: Bool = true,
        showsFooter: Bool = true
    ) -> some View {
        let queryActive = showsSearchInput && nativeSessionPickerQueryActive
        let displayedCount = nativeSessionPickerDisplayedCount

        return VStack(spacing: 0) {
            nativeSessionPickerTopBar(
                showsCreateButton: showsInlineCreateButton,
                showsSearchInput: showsSearchInput
            )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            if showsTopDivider {
                Divider()
            }

            sessionPickerList(
                queryActive: queryActive,
                isSearching: isSessionPickerSearching
            )

            if showsFooter && showsFooterDivider {
                Divider()
            }

            if showsFooter {
                sessionPickerFooter(
                    queryActive: queryActive,
                    displayedCount: displayedCount,
                    isSearching: isSessionPickerSearching
                )
                .padding(.top, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle(NSLocalizedString("会话", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        openSettingsFromSessionPicker()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(NSLocalizedString("设置", comment: "会话选择器设置入口"))
                }
            }
            if !showsInlineCreateButton {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createSessionFromPicker()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("开启新对话", comment: ""))
                }
            }
        }
    }

    func openSettingsFromSessionPicker() {
        chatPickerDismissDestination = .settings
        dismissSessionPicker()
    }

    func applySessionPickerLifecycle<Content: View>(to content: Content) -> some View {
        content
        .onAppear {
            normalizeSessionPickerFolderSelection()
            resetSessionPickerLoadedSessions()
            resetSessionPickerLoadedSearchResults()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: sessionPickerSearchText) { _, newValue in
            isLoadingMoreSessionPickerSearchResults = false
            loadedSessionPickerSearchResults = []
            scheduleSessionPickerSearch(for: newValue)
        }
        .onChange(of: viewModel.chatSessionListVersion) { _, _ in
            normalizeSessionPickerFolderSelection()
            syncLoadedSessionPickerSessionsWithSource()
            syncLoadedSessionPickerSearchResultsWithSource()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.sessionFolderListVersion) { _, _ in
            normalizeSessionPickerFolderSelection()
            syncLoadedSessionPickerSessionsWithSource()
        }
        .onChange(of: sessionPickerFolderID) { _, _ in
            resetSessionPickerLoadedSessions()
            resetSessionPickerLoadedSearchResults()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.allMessageIdentityVersion) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onDisappear {
            cancelSessionPickerPagingTasks()
            sessionPickerPendingSearchWorkItem?.cancel()
            sessionPickerPendingSearchWorkItem = nil
        }
    }

    func nativeSessionPickerTopBar(
        showsCreateButton: Bool = false,
        showsSearchInput: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if showsCreateButton {
                        Text(NSLocalizedString("会话", comment: ""))
                            .etFont(.system(size: 18, weight: .semibold))
                            .foregroundColor(TelegramColors.navBarText)
                    }
                    Text(nativeSessionPickerSubtitle(showsSearchInput: showsSearchInput))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showsCreateButton {
                    Button {
                        performQuickAction(.settings)
                    } label: {
                        Image(systemName: "gearshape")
                            .etFont(.system(size: 14, weight: .semibold))
                            .foregroundColor(TelegramColors.navBarText)
                            .frame(width: 32, height: 32)
                            .background(sessionPickerFooterButtonBackground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("设置", comment: "横屏会话侧栏设置入口"))

                    Button {
                        createSessionFromPicker()
                    } label: {
                        Image(systemName: "plus")
                            .etFont(.system(size: 14, weight: .semibold))
                            .foregroundColor(TelegramColors.navBarText)
                            .frame(width: 32, height: 32)
                            .background(sessionPickerFooterButtonBackground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("开启新对话", comment: ""))
                }
            }

            if showsSearchInput {
                sessionPickerSearchInput
            }
            sessionPickerFolderHeader
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var nativeSessionPickerQueryActive: Bool {
        !SessionHistorySearchSupport.normalizedQuery(sessionPickerSearchText).isEmpty
    }

    var nativeSessionPickerDisplayedCount: Int {
        nativeSessionPickerQueryActive ? totalSessionPickerSearchResultCount : totalSessionPickerCount
    }

    func nativeSessionPickerSubtitle(showsSearchInput: Bool) -> String {
        if showsSearchInput && nativeSessionPickerQueryActive {
            if isSessionPickerSearching {
                return NSLocalizedString("正在搜索历史会话…", comment: "")
            }
            return String(
                format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""),
                nativeSessionPickerDisplayedCount,
                sessionPickerSearchHits.count
            )
        }
        if let folder = sessionPickerCurrentFolder {
            return String(format: NSLocalizedString("文件夹 • %@", comment: ""), sessionPickerFolderPath(folder))
        }
        return NSLocalizedString("快速切换与管理", comment: "")
    }

    @ViewBuilder
    var sessionPickerFolderHeader: some View {
        if let folder = sessionPickerCurrentFolder {
            HStack(spacing: 8) {
                Button {
                    openSessionPickerParentFolder()
                } label: {
                    Image(systemName: "chevron.left")
                        .etFont(.system(size: 12, weight: .bold))
                        .foregroundColor(TelegramColors.navBarText)
                        .frame(width: 26, height: 26)
                        .background(sessionPickerFooterButtonBackground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("返回上一级", comment: "Session picker parent folder accessibility label"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .etFont(.system(size: 13, weight: .semibold))
                        .foregroundColor(TelegramColors.navBarText)
                        .lineLimit(1)
                    Text(sessionPickerFolderPath(folder))
                        .etFont(.system(size: 11.5))
                        .foregroundColor(TelegramColors.navBarSubtitle)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
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
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.6)
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
        bottomContentPadding: CGFloat = 16
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if queryActive && isSearching {
                    sessionPickerSearchingState
                } else if queryActive && totalSessionPickerSearchResultCount == 0 {
                    sessionPickerEmptyState(queryActive: true)
                } else if !queryActive && totalSessionPickerCount == 0 {
                    sessionPickerEmptyState(queryActive: false)
                } else {
                    if queryActive {
                        ForEach(pagedSessionPickerSearchResults) { result in
                            sessionPickerSearchResultRow(result)
                                .onAppear {
                                    loadMoreSessionPickerItemsIfNeeded(currentID: result.id, queryActive: true)
                                }
                        }
                    } else {
                        ForEach(pagedSessionPickerEntries) { entry in
                            sessionPickerEntryRow(entry)
                        }
                    }

                    if isLoadingMoreSessionPickerItems(queryActive: queryActive) || hasMoreSessionPickerItems(queryActive: queryActive) {
                        sessionPickerLoadingMoreFooter(queryActive: queryActive)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomContentPadding)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func sessionPickerFooter(queryActive: Bool, displayedCount: Int, isSearching: Bool) -> some View {
        Text(
            queryActive
            ? (isSearching ? NSLocalizedString("正在搜索…", comment: "") : String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), displayedCount, sessionPickerSearchHits.count))
            : "\(String(format: NSLocalizedString("%d 个文件夹", comment: ""), sessionPickerChildFolders.count)) · \(String(format: NSLocalizedString("%d 个会话", comment: ""), sessionPickerDirectSessions.count))"
        )
        .etFont(.system(size: 12, weight: .medium))
        .foregroundColor(TelegramColors.navBarSubtitle)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
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
}
