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

struct SessionListView: View {
    let createConversationAction: (() -> Void)?

    init(createConversationAction: (() -> Void)? = nil) {
        self.createConversationAction = createConversationAction
    }

    var body: some View {
        SessionFolderBrowserView(
            folderID: nil,
            isRoot: true,
            createConversationAction: createConversationAction
        )
    }
}

struct SessionFolderBrowserView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var syncManager: WatchSyncManager
    @Environment(\.dismiss) var dismiss

    let folderID: UUID?
    let isRoot: Bool
    let createConversationAction: (() -> Void)?

    @State var editingSessionID: UUID?
    @State var draftSessionName: String = ""
    @State var sessionToDelete: ChatSession?
    @State var sessionInfo: SessionInfoPayload?
    @State var showGhostSessionAlert = false
    @State var ghostSession: ChatSession?

    @State var createFolderParentID: UUID?
    @State var createFolderName: String = ""
    @State var isShowingCreateFolderAlert = false

    @State var folderToRename: SessionFolder?
    @State var renameFolderName: String = ""
    @State var isShowingRenameFolderAlert = false

    @State var folderToDelete: SessionFolder?

    @State var isBatchSelecting = false
    @State var selectedSessionIDs: Set<UUID> = []
    @State var selectedFolderIDs: Set<UUID> = []
    @State var showBatchDeleteConfirm = false
    @State var searchText: String = ""
    @State var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State var isSearching: Bool = false
    @State var latestSearchToken: Int = 0
    @State var pendingSearchWorkItem: DispatchWorkItem?
    @State var sessionPageIndex: Int = 0
    @State var searchResultPageIndex: Int = 0

    let maxSessionsPerPage = 100

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

    private var listScaffold: some View {
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

    private var pagedSessionIDs: [UUID] {
        pagedDirectSessions.map(\.id)
    }

    private var childFolderIDs: [UUID] {
        childFolders.map(\.id)
    }
}
