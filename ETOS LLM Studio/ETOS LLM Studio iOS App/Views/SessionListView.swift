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
    @State var loadedDirectSessions: [ChatSession] = []
    @State var loadedSearchResultItems: [SessionHistorySearchResult] = []
    @State var isLoadingMoreSessions: Bool = false
    @State var isLoadingMoreSearchResults: Bool = false
    @State var pendingLoadMoreSessionsTask: Task<Void, Never>?
    @State var pendingLoadMoreSearchResultsTask: Task<Void, Never>?

    let maxSessionsPerPage = 100
    let infiniteScrollTriggerRemainingCount = 10

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

    var pagedDirectSessions: [ChatSession] {
        loadedDirectSessions
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

    var pagedSearchResultItems: [SessionHistorySearchResult] {
        loadedSearchResultItems
    }

    var emptyStateText: String {
        folderID == nil ? NSLocalizedString("暂无文件夹或会话。", comment: "") : NSLocalizedString("当前文件夹暂无内容。", comment: "")
    }

    var hasMoreDirectSessions: Bool {
        loadedDirectSessions.count < totalDirectSessionCount
    }

    var hasMoreSearchResults: Bool {
        loadedSearchResultItems.count < totalSearchResultCount
    }

    var shouldShowLoadingMoreFooter: Bool {
        isSearchActive ? (isLoadingMoreSearchResults || hasMoreSearchResults) : (isLoadingMoreSessions || hasMoreDirectSessions)
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
        let folderEntries = entries.filter {
            if case .folder = $0 { return true }
            return false
        }
        let sessionEntries = entries.filter {
            if case .session = $0 { return true }
            return false
        }
        let baseList = List {
            if isSearchActive {
                searchResultSection
            } else {
                if entries.isEmpty {
                    emptyStateRow
                }

                if !folderEntries.isEmpty {
                    sectionLabelRow(
                        title: NSLocalizedString("文件夹", comment: ""),
                        systemImage: "folder.fill"
                    )
                    ForEach(folderEntries) { entry in
                        mergedEntryRow(entry)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }

                if !sessionEntries.isEmpty {
                    sectionLabelRow(
                        title: NSLocalizedString("会话", comment: ""),
                        systemImage: "bubble.left.and.bubble.right.fill"
                    )
                    ForEach(sessionEntries) { entry in
                        mergedEntryRow(entry)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }

                if shouldShowLoadingMoreFooter {
                    loadingMoreFooter
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isRoot ? NSLocalizedString("会话管理", comment: "") : (currentFolder?.name ?? NSLocalizedString("文件夹", comment: "")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sessionListActionsMenu
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isBatchSelecting && !isSearchActive {
                batchActionBar
            }
        }
        return applySearchModifier(to: baseList)
    }

    /// 把分组标题渲染为普通 row，避免 plain List 的 Section header
    /// 在向上滚动时贴顶并与搜索框毛玻璃穿模。
    private func sectionLabelRow(title: String, systemImage: String?) -> some View {
        SessionGroupHeader(title: title, systemImage: systemImage)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var emptyStateRow: some View {
        Text(emptyStateText)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    var pagedSessionIDs: [UUID] {
        pagedDirectSessions.map(\.id)
    }

    var childFolderIDs: [UUID] {
        childFolders.map(\.id)
    }
}
