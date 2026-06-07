// ============================================================================
// SessionFolderBrowserActions.swift
// ============================================================================
// ETOS LLM Studio Watch App 文件夹浏览器行渲染与批量操作辅助
// ============================================================================

import Foundation
import ETOSCore
import SwiftUI

extension SessionFolderBrowserView {
    func mergedEntryRow(_ entry: SessionMergedEntry) -> AnyView {
        switch entry {
        case .folder(let folder):
            return AnyView(folderRow(folder))
        case .session(let session):
            return AnyView(
                sessionRow(session)
                    .onAppear {
                        loadMoreDirectSessionsIfNeeded(currentID: session.id)
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
                    sessions: $sessions,
                    folders: $folders,
                    tags: tags,
                    currentSession: $currentSession,
                    runningSessionIDs: runningSessionIDs,
                    deleteSessionAction: deleteSessionAction,
                    branchAction: branchAction,
                    deleteLastMessageAction: deleteLastMessageAction,
                    sendSessionToCompanionAction: sendSessionToCompanionAction,
                    onSessionSelected: onSessionSelected,
                    updateSessionAction: updateSessionAction,
                    createFolderAction: createFolderAction,
                    renameFolderAction: renameFolderAction,
                    deleteFolderAction: deleteFolderAction,
                    moveSessionToFolderAction: moveSessionToFolderAction,
                    moveFolderToFolderAction: moveFolderToFolderAction,
                    createTagAction: createTagAction,
                    updateTagAction: updateTagAction,
                    deleteTagAction: deleteTagAction,
                    setSessionTagsAction: setSessionTagsAction,
                    createConversationAction: createConversationAction,
                    isRoot: false
                )
            } label: {
                folderLabel(for: folder)
            }
        }
    }

    @ViewBuilder
    func sessionRow(_ session: ChatSession) -> some View {
        if isBatchSelecting {
            BatchSelectableSessionRow(
                session: session,
                tags: sessionTags(for: session),
                isSelected: selectedSessionIDs.contains(session.id),
                onToggle: {
                    toggleSessionSelection(session.id)
                }
            )
        } else {
            SessionRowView(
                session: session,
                isRunning: runningSessionIDs.contains(session.id),
                currentSession: $currentSession,
                folders: $folders,
                tags: tags,
                sessionTags: sessionTags(for: session),
                sessionToEdit: $sessionToEdit,
                sessionToBranch: $sessionToBranch,
                showBranchOptions: $showBranchOptions,
                sessionToDelete: $sessionToDelete,
                showDeleteSessionConfirm: $showDeleteSessionConfirm,
                onSessionSelected: { selectedSession, messageOrdinal in
                    unlockConversationArchaeologistIfNeeded(for: selectedSession)
                    onSessionSelected(selectedSession, messageOrdinal)
                },
                deleteLastMessageAction: deleteLastMessageAction,
                sendSessionToCompanionAction: sendSessionToCompanionAction,
                moveSessionToFolderAction: moveSessionToFolderAction,
                createTagAction: createTagAction,
                updateTagAction: updateTagAction,
                deleteTagAction: deleteTagAction,
                setSessionTagsAction: setSessionTagsAction
            )
        }
    }

    @ViewBuilder
    func folderLabel(for folder: SessionFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .etFont(.footnote)
                    .lineLimit(1)
                Text(String(format: NSLocalizedString("%d 个会话", comment: ""), recursiveSessionCount(in: folder.id)))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func toggleBatchMode() {
        isBatchSelecting.toggle()
        if !isBatchSelecting {
            selectedSessionIDs.removeAll()
            selectedFolderIDs.removeAll()
        }
    }

    func endBatchMode() {
        isBatchSelecting = false
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    func dismissMoreActionsThen(_ action: @escaping () -> Void) {
        showMoreActions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            action()
        }
    }

    func toggleSessionSelection(_ sessionID: UUID) {
        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    func toggleFolderSelection(_ folderID: UUID) {
        if selectedFolderIDs.contains(folderID) {
            selectedFolderIDs.remove(folderID)
        } else {
            selectedFolderIDs.insert(folderID)
        }
    }

    func toggleTagFilter(_ tagID: UUID) {
        if selectedTagFilterIDs.contains(tagID) {
            selectedTagFilterIDs.remove(tagID)
        } else {
            selectedTagFilterIDs.insert(tagID)
        }
    }

    func applyBatchMove(toFolderID folderID: UUID?) {
        for session in selectedSessions {
            moveSessionToFolderAction(session, folderID)
        }
        for folder in selectedFolders {
            moveFolderToFolderAction(folder, folderID)
        }
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    func isValidBatchMoveTarget(_ targetFolderID: UUID) -> Bool {
        for selectedFolderID in selectedFolderIDs {
            if targetFolderID == selectedFolderID {
                return false
            }
            if folderHierarchyContains(descendantFolderID: targetFolderID, ancestorFolderID: selectedFolderID) {
                return false
            }
        }
        return true
    }

    func performBatchDelete() {
        let targetSessions = selectedSessions
        let targetFolders = selectedFolders
        guard !targetSessions.isEmpty || !targetFolders.isEmpty else { return }
        targetSessions.forEach { deleteSessionAction($0) }
        targetFolders.forEach { deleteFolderAction($0) }
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    var batchDeleteMessage: String {
        let folderText = selectedFolderIDs.isEmpty ? "" : String(format: NSLocalizedString("%d 个文件夹", comment: ""), selectedFolderIDs.count)
        let sessionText = selectedSessionIDs.isEmpty ? "" : String(format: NSLocalizedString("%d 个会话", comment: ""), selectedSessionIDs.count)
        let targetText = [folderText, sessionText]
            .filter { !$0.isEmpty }
            .joined(separator: NSLocalizedString("和", comment: ""))
        let targetSummary = targetText.isEmpty ? NSLocalizedString("所选项目", comment: "") : targetText
        return String(format: NSLocalizedString("将删除 %@。文件夹内的会话会移回未分类，操作不可恢复。", comment: ""), targetSummary)
    }

    func resetLoadedDirectSessions() {
        pendingLoadMoreSessionsTask?.cancel()
        pendingLoadMoreSessionsTask = nil
        isLoadingMoreSessions = false
        loadedDirectSessions = []
        appendInitialDirectSessionsPage()
    }

    func appendInitialDirectSessionsPage() {
        let end = min(maxSessionsPerPage, directSessions.count)
        guard end > 0 else { return }
        loadedDirectSessions = Array(directSessions.prefix(end))
    }

    func scheduleNextDirectSessionsPage() {
        guard !isLoadingMoreSessions, hasMoreDirectSessions, pendingLoadMoreSessionsTask == nil else { return }
        isLoadingMoreSessions = true
        pendingLoadMoreSessionsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else {
                isLoadingMoreSessions = false
                pendingLoadMoreSessionsTask = nil
                return
            }

            let start = loadedDirectSessions.count
            let end = min(start + maxSessionsPerPage, directSessions.count)
            if start < end {
                loadedDirectSessions.append(contentsOf: directSessions[start..<end])
            }
            isLoadingMoreSessions = false
            pendingLoadMoreSessionsTask = nil
        }
    }

    func syncLoadedDirectSessionsWithSource() {
        pendingLoadMoreSessionsTask?.cancel()
        pendingLoadMoreSessionsTask = nil
        isLoadingMoreSessions = false
        let loadedCount = min(max(loadedDirectSessions.count, maxSessionsPerPage), directSessions.count)
        loadedDirectSessions = Array(directSessions.prefix(loadedCount))
    }

    func loadMoreDirectSessionsIfNeeded(currentID: UUID) {
        guard loadedDirectSessions.suffix(infiniteScrollTriggerRemainingCount).contains(where: { $0.id == currentID }) else { return }
        scheduleNextDirectSessionsPage()
    }

    var loadingMoreFooter: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(NSLocalizedString("正在加载", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    func unlockConversationArchaeologistIfNeeded(for session: ChatSession) {
        guard AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(
            selectedSession: session,
            sessions: sessions
        ) else { return }

        Task {
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .conversationArchaeologist)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: .conversationArchaeologist)
        }
    }

    func rebuildSessionBrowserSource() {
        let foldersSnapshot = folders
        let sessionsSnapshot = sessions
        let folderByID = Dictionary(uniqueKeysWithValues: foldersSnapshot.map { ($0.id, $0) })
        let allChildFolders = foldersSnapshot.filter { folder in
            normalizedParentID(of: folder, folderByID: folderByID) == folderID
        }
        let directSessions = sessionsSnapshot.filter { session in
            normalizedFolderID(of: session, folderByID: folderByID) == folderID
                && sessionMatchesTagFilter(session)
        }
        let sessionOrderByID = Dictionary(uniqueKeysWithValues: sessionsSnapshot.enumerated().map { ($1.id, $0) })
        let folderAncestorIDsByFolderID = folderAncestorLookup(
            folders: foldersSnapshot,
            folderByID: folderByID
        )

        var recentActivityIndexByFolderID: [UUID: Int] = [:]
        var recursiveSessionCountByFolderID: [UUID: Int] = [:]
        for folder in foldersSnapshot {
            recentActivityIndexByFolderID[folder.id] = .max
            recursiveSessionCountByFolderID[folder.id] = 0
        }

        for (index, session) in sessionsSnapshot.enumerated() {
            guard sessionMatchesTagFilter(session),
                  let assignedFolderID = normalizedFolderID(of: session, folderByID: folderByID) else { continue }
            for ancestorID in folderAncestorIDsByFolderID[assignedFolderID, default: []] {
                recursiveSessionCountByFolderID[ancestorID, default: 0] += 1
                recentActivityIndexByFolderID[ancestorID] = min(
                    recentActivityIndexByFolderID[ancestorID, default: .max],
                    index
                )
            }
        }

        cachedFolderByID = folderByID
        cachedChildFolders = isTagFilterActive
            ? allChildFolders.filter { recursiveSessionCountByFolderID[$0.id, default: 0] > 0 }
            : allChildFolders
        cachedDirectSessions = directSessions
        cachedSessionOrderByID = sessionOrderByID
        cachedRecentActivityIndexByFolderID = recentActivityIndexByFolderID
        cachedRecursiveSessionCountByFolderID = recursiveSessionCountByFolderID
        hasPreparedSessionBrowserSource = true
    }

    func folderAncestorLookup(
        folders: [SessionFolder],
        folderByID: [UUID: SessionFolder]
    ) -> [UUID: [UUID]] {
        var lookup: [UUID: [UUID]] = [:]
        for folder in folders {
            var ancestors: [UUID] = []
            var cursor: UUID? = folder.id
            var visited = Set<UUID>()
            while let current = cursor {
                guard visited.insert(current).inserted else { break }
                ancestors.append(current)
                guard let folder = folderByID[current] else { break }
                cursor = normalizedParentID(of: folder, folderByID: folderByID)
            }
            lookup[folder.id] = ancestors
        }
        return lookup
    }

    func normalizedFolderID(
        of session: ChatSession,
        folderByID: [UUID: SessionFolder]
    ) -> UUID? {
        guard let folderID = session.folderID else { return nil }
        return folderByID[folderID] == nil ? nil : folderID
    }

    func normalizedParentID(
        of folder: SessionFolder,
        folderByID: [UUID: SessionFolder]
    ) -> UUID? {
        guard let parentID = folder.parentID else { return nil }
        return folderByID[parentID] == nil ? nil : parentID
    }

    func openCreateFolderEditor(parentID: UUID?) {
        folderBeingRenamed = nil
        folderEditorParentID = parentID
        folderEditorName = ""
        isShowingFolderEditor = true
    }

    func openRenameFolderEditor(_ folder: SessionFolder) {
        folderBeingRenamed = folder
        folderEditorParentID = nil
        folderEditorName = folder.name
        isShowingFolderEditor = true
    }

    func resetFolderEditorState() {
        folderBeingRenamed = nil
        folderEditorParentID = nil
        folderEditorName = ""
    }

    func normalizedFolderID(of session: ChatSession) -> UUID? {
        guard let folderID = session.folderID else { return nil }
        return folderByID[folderID] == nil ? nil : folderID
    }

    func normalizedParentID(of folder: SessionFolder) -> UUID? {
        guard let parentID = folder.parentID else { return nil }
        return folderByID[parentID] == nil ? nil : parentID
    }

    func recentActivityIndex(for folderID: UUID) -> Int {
        if hasPreparedSessionBrowserSource, let cached = cachedRecentActivityIndexByFolderID[folderID] {
            return cached
        }
        for (index, session) in sessions.enumerated() {
            guard sessionMatchesTagFilter(session),
                  let assignedFolderID = normalizedFolderID(of: session) else { continue }
            if folderHierarchyContains(descendantFolderID: assignedFolderID, ancestorFolderID: folderID) {
                return index
            }
        }
        return .max
    }

    func folderHierarchyContains(descendantFolderID: UUID, ancestorFolderID: UUID) -> Bool {
        var cursor: UUID? = descendantFolderID
        var visited = Set<UUID>()
        while let current = cursor {
            if current == ancestorFolderID {
                return true
            }
            guard visited.insert(current).inserted else { return false }
            cursor = folderByID[current]?.parentID
        }
        return false
    }

    func descendantFolderIDs(rootID: UUID) -> Set<UUID> {
        var collected: Set<UUID> = [rootID]
        var queue: [UUID] = [rootID]

        while let current = queue.first {
            queue.removeFirst()
            let children = folders.filter { normalizedParentID(of: $0) == current }
            for child in children where collected.insert(child.id).inserted {
                queue.append(child.id)
            }
        }

        return collected
    }

    func recursiveSessionCount(in folderID: UUID) -> Int {
        if hasPreparedSessionBrowserSource {
            return cachedRecursiveSessionCountByFolderID[folderID, default: 0]
        }
        let descendants = descendantFolderIDs(rootID: folderID)
        return sessions.filter { session in
            guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID) && sessionMatchesTagFilter(session)
        }.count
    }

    func sessionTags(for session: ChatSession) -> [SessionTag] {
        let tagByID = tags.reduce(into: [UUID: SessionTag]()) { result, tag in
            result[tag.id] = tag
        }
        return session.tagIDs.compactMap { tagByID[$0] }
    }

    func sessionMatchesTagFilter(_ session: ChatSession) -> Bool {
        guard !selectedTagFilterIDs.isEmpty else { return true }
        return session.tagIDs.contains { selectedTagFilterIDs.contains($0) }
    }

    func folderContainsTagFilteredSession(_ folderID: UUID) -> Bool {
        let descendants = descendantFolderIDs(rootID: folderID)
        return sessions.contains { session in
            guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID) && sessionMatchesTagFilter(session)
        }
    }

    var tagFilterSummary: String {
        selectedTagFilters.map(\.name).joined(separator: NSLocalizedString("、", comment: "List separator"))
    }

    func folderPath(_ folder: SessionFolder) -> String {
        var parts: [String] = [folder.name]
        var cursor = folder.parentID
        var visited = Set<UUID>()

        while let current = cursor {
            guard visited.insert(current).inserted else { break }
            guard let parent = folderByID[current] else { break }
            parts.append(parent.name)
            cursor = parent.parentID
        }

        return parts.reversed().joined(separator: " /")
    }
}
