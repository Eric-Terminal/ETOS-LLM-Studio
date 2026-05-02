// ============================================================================
// SessionListView.swift
// ============================================================================
// 会话管理界面 (iOS)
// - 文件夹与会话合并展示，保持文件管理式浏览
// - 支持新建/重命名/删除文件夹
// - 支持批量选择会话/文件夹并批量移动、批量删除
// ============================================================================

import Foundation
import Shared
import SwiftUI

extension SessionFolderBrowserView {

    var folderByID: [UUID: SessionFolder] {
        Dictionary(uniqueKeysWithValues: viewModel.sessionFolders.map { ($0.id, $0) })
    }

    var currentFolder: SessionFolder? {
        guard let folderID else { return nil }
        return folderByID[folderID]
    }

    var childFolders: [SessionFolder] {
        viewModel.sessionFolders.filter { normalizedParentID(of: $0) == folderID }
    }

    var directSessions: [ChatSession] {
        viewModel.chatSessions.filter { normalizedFolderID(of: $0) == folderID }
    }

    var totalDirectSessionCount: Int {
        directSessions.count
    }

    var totalSessionPages: Int {
        guard totalDirectSessionCount > 0 else { return 1 }
        return ((totalDirectSessionCount - 1) / maxSessionsPerPage) + 1
    }

    var shouldShowPaginationBar: Bool {
        totalDirectSessionCount > maxSessionsPerPage
    }

    var pagedDirectSessions: [ChatSession] {
        guard totalDirectSessionCount > 0 else { return [] }
        let start = min(sessionPageIndex * maxSessionsPerPage, totalDirectSessionCount)
        let end = min(start + maxSessionsPerPage, totalDirectSessionCount)
        guard start < end else { return [] }
        return Array(directSessions[start..<end])
    }

    var sessionOrderByID: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: viewModel.chatSessions.enumerated().map { ($1.id, $0) })
    }

    var mergedEntries: [SessionMergedEntry] {
        let folders = childFolders.map {
            SessionMergedEntryWithRank(
                rank: recentActivityIndex(for: $0.id),
                entry: .folder($0)
            )
        }
        let sessions = pagedDirectSessions.map {
            SessionMergedEntryWithRank(
                rank: sessionOrderByID[$0.id] ?? .max,
                entry: .session($0)
            )
        }

        return (folders + sessions)
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                switch (lhs.entry, rhs.entry) {
                case (.folder(let left), .folder(let right)):
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                case (.session(let left), .session(let right)):
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                case (.folder, .session):
                    return true
                case (.session, .folder):
                    return false
                }
            }
            .map(\.entry)
    }

    var moveFolderOptions: [SessionMoveFolderOption] {
        viewModel.sessionFolders
            .sorted { lhs, rhs in
                let left = folderDisplayPath(lhs)
                let right = folderDisplayPath(rhs)
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            .map { folder in
                SessionMoveFolderOption(id: folder.id, title: folderDisplayPath(folder))
            }
    }

    var batchMoveFolderOptions: [SessionMoveFolderOption] {
        moveFolderOptions.filter { isValidBatchMoveTarget($0.id) }
    }

    var selectedSessions: [ChatSession] {
        pagedDirectSessions.filter { selectedSessionIDs.contains($0.id) }
    }

    var selectedFolders: [SessionFolder] {
        childFolders.filter { selectedFolderIDs.contains($0.id) }
    }

    var selectedBatchItemCount: Int {
        selectedSessionIDs.count + selectedFolderIDs.count
    }

    var hasBatchSelection: Bool {
        selectedBatchItemCount > 0
    }

    var normalizedSearchQuery: String {
        SessionHistorySearchSupport.normalizedQuery(searchText)
    }

    var isSearchActive: Bool {
        isRoot && !normalizedSearchQuery.isEmpty
    }

    var searchResultSessions: [ChatSession] {
        guard isSearchActive else { return [] }
        return viewModel.chatSessions.filter { searchHits[$0.id] != nil }
    }

    var searchResultItems: [SessionHistorySearchResult] {
        guard isSearchActive else { return [] }
        return SessionHistorySearchSupport.flattenedResults(
            sessions: viewModel.chatSessions,
            hits: searchHits
        )
    }

    var totalSearchResultCount: Int {
        searchResultItems.count
    }

    var totalSearchResultPages: Int {
        guard totalSearchResultCount > 0 else { return 1 }
        return ((totalSearchResultCount - 1) / maxSessionsPerPage) + 1
    }

    var shouldShowSearchPaginationBar: Bool {
        totalSearchResultCount > maxSessionsPerPage
    }

    var pagedSearchResultItems: [SessionHistorySearchResult] {
        guard totalSearchResultCount > 0 else { return [] }
        let start = min(searchResultPageIndex * maxSessionsPerPage, totalSearchResultCount)
        let end = min(start + maxSessionsPerPage, totalSearchResultCount)
        guard start < end else { return [] }
        return Array(searchResultItems[start..<end])
    }

    var emptyStateText: String {
        folderID == nil ? NSLocalizedString("暂无文件夹或会话。", comment: "") : NSLocalizedString("当前文件夹暂无内容。", comment: "")
    }

    var canGoToPreviousPage: Bool {
        sessionPageIndex > 0
    }

    var canGoToNextPage: Bool {
        sessionPageIndex + 1 < totalSessionPages
    }

    var canGoToPreviousSearchResultPage: Bool {
        searchResultPageIndex > 0
    }

    var canGoToNextSearchResultPage: Bool {
        searchResultPageIndex + 1 < totalSearchResultPages
    }

    var currentPageStartOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return sessionPageIndex * maxSessionsPerPage + 1
    }

    var currentPageEndOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return min((sessionPageIndex + 1) * maxSessionsPerPage, totalDirectSessionCount)
    }

    var currentSearchResultPageStartOrdinal: Int {
        guard totalSearchResultCount > 0 else { return 0 }
        return searchResultPageIndex * maxSessionsPerPage + 1
    }

    var currentSearchResultPageEndOrdinal: Int {
        guard totalSearchResultCount > 0 else { return 0 }
        return min((searchResultPageIndex + 1) * maxSessionsPerPage, totalSearchResultCount)
    }

    var paginationSummaryText: String {
        String(format: NSLocalizedString("当前显示%d-%d个对话(总共%d)", comment: ""), currentPageStartOrdinal, currentPageEndOrdinal, totalDirectSessionCount)
    }

    var searchPaginationSummaryText: String {
        String(format: NSLocalizedString("当前显示%d-%d条结果(总共%d)", comment: ""), currentSearchResultPageStartOrdinal, currentSearchResultPageEndOrdinal, totalSearchResultCount)
    }

    var shouldShowActivePaginationBar: Bool {
        isSearchActive ? shouldShowSearchPaginationBar : shouldShowPaginationBar
    }

    var activePaginationSummaryText: String {
        isSearchActive ? searchPaginationSummaryText : paginationSummaryText
    }

    var canGoToPreviousActivePage: Bool {
        isSearchActive ? canGoToPreviousSearchResultPage : canGoToPreviousPage
    }

    var canGoToNextActivePage: Bool {
        isSearchActive ? canGoToNextSearchResultPage : canGoToNextPage
    }

    var body: some View {
        applySheetAndGhostAlert(
            to: applyDeleteFolderAlert(
                to: applyFolderEditingAlerts(
                    to: applySessionAlerts(
                        to: applyStateHandlers(to: listScaffold)
                    )
                )
            )
        )
    }

    var listScaffold: some View {
        let entries = mergedEntries
        let baseList = List {
            if isSearchActive {
                searchResultSection
            } else {
                if entries.isEmpty {
                    Text(emptyStateText)
                        .foregroundStyle(.secondary)
                }

                ForEach(entries) { entry in
                    mergedEntryRow(entry)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(isRoot ? NSLocalizedString("会话管理", comment: "") : (currentFolder?.name ?? NSLocalizedString("文件夹", comment: "")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sessionListActionsMenu
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isBatchSelecting && !isSearchActive {
                batchActionBar
            } else if shouldShowActivePaginationBar {
                paginationBar
            }
        }
        return applySearchModifier(to: baseList)
    }

    var pagedSessionIDs: [UUID] {
        pagedDirectSessions.map(\.id)
    }

    var childFolderIDs: [UUID] {
        childFolders.map(\.id)
    }

    func applyStateHandlers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: viewModel.sessionFolderListVersion) { _, _ in
                guard folderID != nil else { return }
                if currentFolder == nil {
                    dismiss()
                }
            }
            .onChange(of: pagedSessionIDs) { _, visibleIDs in
                selectedSessionIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: childFolderIDs) { _, visibleIDs in
                selectedFolderIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: totalDirectSessionCount) { _, _ in
                normalizeSessionPageIndex()
            }
            .onChange(of: totalSearchResultCount) { _, _ in
                normalizeSearchResultPageIndex()
            }
            .onAppear {
                normalizeSessionPageIndex()
                normalizeSearchResultPageIndex()
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: searchText) { _, newValue in
                guard isRoot else { return }
                if !SessionHistorySearchSupport.normalizedQuery(newValue).isEmpty, isBatchSelecting {
                    isBatchSelecting = false
                    selectedSessionIDs.removeAll()
                    selectedFolderIDs.removeAll()
                }
                searchResultPageIndex = 0
                scheduleSearch(for: newValue)
            }
            .onChange(of: viewModel.chatSessionListVersion) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: viewModel.currentSession?.id) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: viewModel.allMessageIdentityVersion) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onDisappear {
                guard isRoot else { return }
                pendingSearchWorkItem?.cancel()
                pendingSearchWorkItem = nil
            }
    }

    func applySessionAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert(NSLocalizedString("确认删除会话", comment: ""), isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionToDelete = nil
                    }
                }
            )) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let session = sessionToDelete {
                        viewModel.deleteSessions([session])
                    }
                    sessionToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("删除后所有消息也将被移除，操作不可恢复。", comment: ""))
            }
            .alert(NSLocalizedString("确认批量删除", comment: ""), isPresented: $showBatchDeleteConfirm) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    performBatchDelete()
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            } message: {
                Text(batchDeleteMessage)
            }
    }

    func applyFolderEditingAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert(NSLocalizedString("新建文件夹", comment: ""), isPresented: $isShowingCreateFolderAlert) {
                TextField(NSLocalizedString("文件夹名称", comment: ""), text: $createFolderName)
                Button(NSLocalizedString("创建", comment: "")) {
                    let trimmed = createFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = viewModel.createSessionFolder(name: trimmed, parentID: createFolderParentID)
                    createFolderName = ""
                    createFolderParentID = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    createFolderName = ""
                    createFolderParentID = nil
                }
            } message: {
                if let createFolderParentID,
                   let parentFolder = folderByID[createFolderParentID] {
                    Text(String(format: NSLocalizedString("将在“%@”下创建子文件夹。", comment: ""), parentFolder.name))
                } else {
                    Text(NSLocalizedString("请输入新的文件夹名称。", comment: ""))
                }
            }
            .alert(NSLocalizedString("重命名文件夹", comment: ""), isPresented: $isShowingRenameFolderAlert) {
                TextField(NSLocalizedString("文件夹名称", comment: ""), text: $renameFolderName)
                Button(NSLocalizedString("保存", comment: "")) {
                    guard let folderToRename else { return }
                    let trimmed = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    viewModel.renameSessionFolder(folderToRename, newName: trimmed)
                    self.folderToRename = nil
                    renameFolderName = ""
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    folderToRename = nil
                    renameFolderName = ""
                }
            } message: {
                Text(NSLocalizedString("请输入新的文件夹名称。", comment: ""))
            }
    }

    func applyDeleteFolderAlert<Content: View>(to content: Content) -> some View {
        content
            .alert(NSLocalizedString("确认删除文件夹", comment: ""), isPresented: Binding(
                get: { folderToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        folderToDelete = nil
                    }
                }
            )) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let folderToDelete {
                        viewModel.deleteSessionFolder(folderToDelete)
                    }
                    folderToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    folderToDelete = nil
                }
            } message: {
                if let folderToDelete {
                    let descendantIDs = descendantFolderIDs(rootID: folderToDelete.id)
                    let folderCount = descendantIDs.count
                    let affectedSessions = viewModel.chatSessions.filter { session in
                        guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
                        return descendantIDs.contains(assignedFolderID)
                    }.count
                    Text(String(format: NSLocalizedString("将删除 %d 个文件夹。%d 个会话将移回未分类。", comment: ""), folderCount, affectedSessions))
                }
            }
    }

    func applySheetAndGhostAlert<Content: View>(to content: Content) -> some View {
        content
            .sheet(item: $sessionInfo) { info in
                SessionInfoSheet(payload: info)
            }
            .alert(NSLocalizedString("发现幽灵会话", comment: ""), isPresented: $showGhostSessionAlert) {
                Button(NSLocalizedString("删除幽灵", comment: ""), role: .destructive) {
                    if let session = ghostSession {
                        viewModel.deleteSessions([session])
                    }
                    ghostSession = nil
                }
                Button(NSLocalizedString("稍后处理", comment: ""), role: .cancel) {
                    ghostSession = nil
                }
            } message: {
                Text(NSLocalizedString("这个会话的消息文件已经丢失了，只剩下一个空壳在这里游荡。\n\n要帮它超度吗？", comment: ""))
            }
    }

    func applySearchModifier<Content: View>(to content: Content) -> some View {
        if isRoot {
            return AnyView(
                content
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(NSLocalizedString("搜索会话标题或消息", comment: ""))
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            )
        }
        return AnyView(content)
    }

    @ViewBuilder
    var searchResultSection: some View {
        Section {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString("正在搜索历史会话…", comment: ""))
                        .foregroundStyle(.secondary)
                }
            } else if searchResultSessions.isEmpty {
                Text(NSLocalizedString("未找到匹配的搜索结果。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pagedSearchResultItems) { result in
                    searchResultRow(result)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                }
            }
        } header: {
            Text(NSLocalizedString("搜索结果", comment: ""))
        } footer: {
            if !isSearching {
                Text(String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), searchResultItems.count, searchResultSessions.count))
            }
        }
    }

    var batchActionBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    applyBatchMove(toFolderID: nil)
                } label: {
                    Label(NSLocalizedString("未分类", comment: ""), systemImage: "tray")
                }

                ForEach(batchMoveFolderOptions) { option in
                    Button {
                        applyBatchMove(toFolderID: option.id)
                    } label: {
                        Label(option.title, systemImage: "folder")
                    }
                }
            } label: {
                Label(NSLocalizedString("移动", comment: ""), systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasBatchSelection)

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasBatchSelection)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    var paginationBar: some View {
        HStack(spacing: 10) {
            paginationButton(
                systemName: "chevron.left",
                accessibilityLabel: NSLocalizedString("上一页", comment: ""),
                isEnabled: canGoToPreviousActivePage,
                action: goToPreviousActivePage
            )

            paginationSummaryField

            paginationButton(
                systemName: "chevron.right",
                accessibilityLabel: NSLocalizedString("下一页", comment: ""),
                isEnabled: canGoToNextActivePage,
                action: goToNextActivePage
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    var paginationSummaryField: some View {
        let field = Text(activePaginationSummaryText)
            .etFont(.callout)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)

        if #available(iOS 26.0, *) {
            field
                .glassEffect(.clear, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        } else {
            field
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule()
                        .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
                )
        }
    }

    func paginationButton(
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
                .etFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .background(paginationButtonBackground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    var paginationButtonBackground: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(Color.clear)
                .glassEffect(.clear, in: Circle())
                .overlay(
                    Circle()
                        .fill(Color(uiColor: .systemBackground).opacity(0.22))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
                )
        }
    }

    func mergedEntryRow(_ entry: SessionMergedEntry) -> AnyView {
        switch entry {
        case .folder(let folder):
            return AnyView(folderRow(folder))
        case .session(let session):
            return AnyView(
                sessionRow(session)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !isBatchSelecting {
                            Button(role: .destructive) {
                                sessionToDelete = session
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                    }
            )
        }
    }

    @ViewBuilder
    func folderRow(_ folder: SessionFolder) -> some View {
        if isBatchSelecting {
            BatchSelectableFolderRow(
                folder: folder,
                sessionCount: recursiveSessionCount(in: folder.id),
                isSelected: selectedFolderIDs.contains(folder.id),
                onToggle: {
                    toggleFolderSelection(folder.id)
                }
            )
        } else {
            NavigationLink {
                SessionFolderBrowserView(
                    folderID: folder.id,
                    isRoot: false,
                    createConversationAction: createConversationAction
                )
            } label: {
                folderLabel(for: folder)
            }
            .contextMenu {
                Button {
                    startRenaming(folder)
                } label: {
                    Label(NSLocalizedString("重命名文件夹", comment: ""), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    folderToDelete = folder
                } label: {
                    Label(NSLocalizedString("删除文件夹", comment: ""), systemImage: "trash")
                }
            }
        }
    }
}
