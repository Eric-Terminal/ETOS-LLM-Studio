// ============================================================================
// SessionFolderBrowserView.swift
// ============================================================================
// ETOS LLM Studio Watch App 文件夹浏览主体视图
// ============================================================================

import Foundation
import Shared
import SwiftUI

struct SessionFolderBrowserView: View {
    let folderID: UUID?

    @Binding var sessions: [ChatSession]
    @Binding var folders: [SessionFolder]
    let tags: [SessionTag]
    @Binding var currentSession: ChatSession?
    let runningSessionIDs: Set<UUID>

    let deleteSessionAction: (ChatSession) -> Void
    let branchAction: (ChatSession, Bool) -> ChatSession?
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let onSessionSelected: (ChatSession, Int?) -> Void
    let updateSessionAction: (ChatSession) -> Void
    let createFolderAction: (String, UUID?) -> SessionFolder?
    let renameFolderAction: (SessionFolder, String) -> Void
    let deleteFolderAction: (SessionFolder) -> Void
    let moveSessionToFolderAction: (ChatSession, UUID?) -> Void
    let moveFolderToFolderAction: (SessionFolder, UUID?) -> Void
    let createTagAction: (String, SessionTagColor?) -> SessionTag?
    let updateTagAction: (SessionTag, String, SessionTagColor?) -> Void
    let deleteTagAction: (SessionTag) -> Void
    let setSessionTagsAction: (ChatSession, [UUID]) -> Void
    let toggleSessionColorMarkerAction: (ChatSession, SessionTagColor?) -> Void
    let createConversationAction: (() -> Void)?
    let isRoot: Bool

    @Environment(\.dismiss) private var dismiss

    @State var showDeleteSessionConfirm: Bool = false
    @State var sessionToDelete: ChatSession?
    @State var sessionToEdit: ChatSession?
    @State var showBranchOptions: Bool = false
    @State var sessionToBranch: ChatSession?

    @State var isShowingFolderEditor = false
    @State var folderEditorName: String = ""
    @State var folderEditorParentID: UUID?
    @State var folderBeingRenamed: SessionFolder?
    @State var folderToDelete: SessionFolder?
    @State var showMoreActions = false

    @State var isBatchSelecting = false
    @State var selectedSessionIDs: Set<UUID> = []
    @State var selectedFolderIDs: Set<UUID> = []
    @State var showBatchDeleteConfirm = false
    @State var showSessionSearch = false
    @State var showTagManagement = false
    @State var sessionForTagEditing: ChatSession?
    @State var selectedTagFilterIDs: Set<UUID> = []
    @State var loadedDirectSessions: [ChatSession] = []
    @State var isLoadingMoreSessions = false
    @State var pendingLoadMoreSessionsTask: Task<Void, Never>?
    @State var hasPreparedSessionBrowserSource = false
    @State var cachedFolderByID: [UUID: SessionFolder] = [:]
    @State var cachedChildFolders: [SessionFolder] = []
    @State var cachedDirectSessions: [ChatSession] = []
    @State var cachedSessionOrderByID: [UUID: Int] = [:]
    @State var cachedRecentActivityIndexByFolderID: [UUID: Int] = [:]
    @State var cachedRecursiveSessionCountByFolderID: [UUID: Int] = [:]

    let maxSessionsPerPage = 50
    let infiniteScrollTriggerRemainingCount = 10

    var folderByID: [UUID: SessionFolder] {
        if hasPreparedSessionBrowserSource {
            return cachedFolderByID
        }
        return Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    }

    var currentFolder: SessionFolder? {
        guard let folderID else { return nil }
        return folderByID[folderID]
    }

    var childFolders: [SessionFolder] {
        if hasPreparedSessionBrowserSource {
            return cachedChildFolders
        }
        let childFolders = folders.filter { normalizedParentID(of: $0) == folderID }
        guard isTagFilterActive else { return childFolders }
        return childFolders.filter { folderContainsTagFilteredSession($0.id) }
    }

    var directSessions: [ChatSession] {
        if hasPreparedSessionBrowserSource {
            return cachedDirectSessions
        }
        return sessions.filter {
            normalizedFolderID(of: $0) == folderID && sessionMatchesTagFilter($0)
        }
    }

    var totalDirectSessionCount: Int {
        directSessions.count
    }

    var pagedDirectSessions: [ChatSession] {
        loadedDirectSessions
    }

    var sessionOrderByID: [UUID: Int] {
        if hasPreparedSessionBrowserSource {
            return cachedSessionOrderByID
        }
        return Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
    }

    var mergedEntries: [SessionMergedEntry] {
        let folderEntries = childFolders.map {
            SessionMergedEntryWithRank(
                rank: recentActivityIndex(for: $0.id),
                entry: .folder($0)
            )
        }

        let sessionEntries = pagedDirectSessions.map {
            SessionMergedEntryWithRank(
                rank: sessionOrderByID[$0.id] ?? .max,
                entry: .session($0)
            )
        }

        return (folderEntries + sessionEntries)
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

    var moveTargets: [SessionMoveTarget] {
        folders
            .sorted { lhs, rhs in
                let left = folderPath(lhs)
                let right = folderPath(rhs)
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            .map { folder in
                SessionMoveTarget(id: folder.id, title: folderPath(folder))
            }
    }

    var batchMoveTargets: [SessionMoveTarget] {
        moveTargets.filter { isValidBatchMoveTarget($0.id) }
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

    var isTagFilterActive: Bool {
        !selectedTagFilterIDs.isEmpty
    }

    var selectedTagFilters: [SessionTag] {
        tags.filter { selectedTagFilterIDs.contains($0.id) }
    }

    var emptyStateText: String {
        folderID == nil ? NSLocalizedString("暂无文件夹或会话。", comment: "") : NSLocalizedString("当前文件夹暂无内容。", comment: "")
    }

    var hasMoreDirectSessions: Bool {
        loadedDirectSessions.count < totalDirectSessionCount
    }

    var shouldShowLoadingMoreFooter: Bool {
        isLoadingMoreSessions || hasMoreDirectSessions
    }

    var body: some View {
        applyDialogs(to: applySheets(to: applyStateHandlers(to: listScaffold)))
    }

    var listScaffold: some View {
        List {
            if isTagFilterActive {
                Button {
                    selectedTagFilterIDs.removeAll()
                    rebuildSessionBrowserSource()
                    resetLoadedDirectSessions()
                } label: {
                    Label(tagFilterSummary, systemImage: "line.3.horizontal.decrease.circle")
                        .etFont(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            if mergedEntries.isEmpty {
                Text(emptyStateText)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(mergedEntries) { entry in
                mergedEntryRow(entry)
            }

            if shouldShowLoadingMoreFooter {
                loadingMoreFooter
            }
        }
        .navigationTitle(isRoot ? NSLocalizedString("历史会话", comment: "") : (currentFolder?.name ?? NSLocalizedString("文件夹", comment: "")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMoreActions = true
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .navigationDestination(isPresented: $showSessionSearch) {
            WatchSessionSearchView(
                sessions: sessions.filter { sessionMatchesTagFilter($0) },
                folders: folders,
                currentSessionID: currentSession?.id,
                onSelect: { session, messageOrdinal in
                    unlockConversationArchaeologistIfNeeded(for: session)
                    onSessionSelected(session, messageOrdinal)
                }
            )
        }
    }

    var pagedSessionIDs: [UUID] {
        pagedDirectSessions.map(\.id)
    }

    var childFolderIDs: [UUID] {
        childFolders.map(\.id)
    }

    func applyStateHandlers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: folders) { _, _ in
                rebuildSessionBrowserSource()
                syncLoadedDirectSessionsWithSource()
                guard folderID != nil else { return }
                if currentFolder == nil {
                    dismiss()
                }
            }
            .onChange(of: sessions) { _, _ in
                rebuildSessionBrowserSource()
                syncLoadedDirectSessionsWithSource()
            }
            .onChange(of: tags) { _, _ in
                selectedTagFilterIDs.formIntersection(Set(tags.map(\.id)))
                rebuildSessionBrowserSource()
                syncLoadedDirectSessionsWithSource()
            }
            .onChange(of: selectedTagFilterIDs) { _, _ in
                rebuildSessionBrowserSource()
                resetLoadedDirectSessions()
            }
            .onChange(of: pagedSessionIDs) { _, visibleIDs in
                selectedSessionIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: childFolderIDs) { _, visibleIDs in
                selectedFolderIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: totalDirectSessionCount) { _, _ in
                syncLoadedDirectSessionsWithSource()
            }
            .onAppear {
                rebuildSessionBrowserSource()
                resetLoadedDirectSessions()
            }
            .onDisappear {
                pendingLoadMoreSessionsTask?.cancel()
                pendingLoadMoreSessionsTask = nil
                isLoadingMoreSessions = false
            }
    }

}
