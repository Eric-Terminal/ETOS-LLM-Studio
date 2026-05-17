// ============================================================================
// SessionFolderBrowserActions.swift
// ============================================================================
// ETOS LLM Studio Watch App 文件夹浏览器行渲染与批量操作辅助
// ============================================================================

import Foundation
import Shared
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
                sessionToEdit: $sessionToEdit,
                sessionToBranch: $sessionToBranch,
                showBranchOptions: $showBranchOptions,
                sessionToDelete: $sessionToDelete,
                showDeleteSessionConfirm: $showDeleteSessionConfirm,
                onSessionSelected: onSessionSelected,
                deleteLastMessageAction: deleteLastMessageAction,
                sendSessionToCompanionAction: sendSessionToCompanionAction,
                moveSessionToFolderAction: moveSessionToFolderAction
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
        isLoadingMoreSessions = false
        loadedDirectSessions = []
        appendNextDirectSessionsPage()
    }

    func appendNextDirectSessionsPage() {
        guard !isLoadingMoreSessions, hasMoreDirectSessions else { return }
        isLoadingMoreSessions = true

        let source = directSessions
        let start = loadedDirectSessions.count
        let end = min(start + maxSessionsPerPage, source.count)
        guard start < end else {
            isLoadingMoreSessions = false
            return
        }
        loadedDirectSessions.append(contentsOf: source[start..<end])
        unlockConversationArchaeologistIfNeeded()
        DispatchQueue.main.async {
            isLoadingMoreSessions = false
        }
    }

    func syncLoadedDirectSessionsWithSource() {
        let loadedCount = min(max(loadedDirectSessions.count, maxSessionsPerPage), directSessions.count)
        loadedDirectSessions = Array(directSessions.prefix(loadedCount))
        unlockConversationArchaeologistIfNeeded()
    }

    func loadMoreDirectSessionsIfNeeded(currentID: UUID) {
        guard loadedDirectSessions.suffix(infiniteScrollTriggerRemainingCount).contains(where: { $0.id == currentID }) else { return }
        appendNextDirectSessionsPage()
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

    func unlockConversationArchaeologistIfNeeded() {
        let totalPages = max(((totalDirectSessionCount - 1) / maxSessionsPerPage) + 1, 1)
        let loadedPageIndex = max((loadedDirectSessions.count - 1) / maxSessionsPerPage, 0)
        guard AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(
            totalSessions: totalDirectSessionCount,
            pageIndex: loadedPageIndex,
            totalPages: totalPages
        ) else { return }

        Task {
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .conversationArchaeologist)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: .conversationArchaeologist)
        }
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
        for (index, session) in sessions.enumerated() {
            guard let assignedFolderID = normalizedFolderID(of: session) else { continue }
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
        let descendants = descendantFolderIDs(rootID: folderID)
        return sessions.filter { session in
            guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID)
        }.count
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
