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

    var sessionListActionsMenu: some View {
        Menu {
            if let createConversationAction {
                Button {
                    createConversationAction()
                } label: {
                    Label(NSLocalizedString("新建对话", comment: ""), systemImage: "plus.message")
                }
            }

            Button {
                presentCreateFolder(parentID: folderID)
            } label: {
                Label(folderID == nil ? NSLocalizedString("新建文件夹", comment: "") : NSLocalizedString("新建子文件夹", comment: ""), systemImage: "folder.badge.plus")
            }

            Button {
                toggleBatchMode()
            } label: {
                Label(
                    isBatchSelecting ? NSLocalizedString("结束批量选择", comment: "") : NSLocalizedString("批量选择", comment: ""),
                    systemImage: isBatchSelecting ? "checkmark.circle.fill" : "pencil"
                )
            }
            .disabled(isSearchActive)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    func sessionRow(
        _ session: ChatSession,
        forceRegularMode: Bool = false,
        searchSummary: String? = nil,
        locationSummary: String? = nil
    ) -> some View {
        if isBatchSelecting && !forceRegularMode {
            BatchSelectableSessionRow(
                session: session,
                isSelected: selectedSessionIDs.contains(session.id),
                onToggle: {
                    toggleSessionSelection(session.id)
                }
            )
        } else {
            SessionRow(
                session: session,
                isCurrent: session.id == viewModel.currentSession?.id,
                isRunning: viewModel.runningSessionIDs.contains(session.id),
                isEditing: editingSessionID == session.id,
                draftName: editingSessionID == session.id ? $draftSessionName : .constant(session.name),
                currentFolderID: normalizedFolderID(of: session),
                moveOptions: moveFolderOptions,
                searchSummary: searchSummary,
                locationSummary: locationSummary,
                onCommit: { newName in
                    viewModel.updateSessionName(session, newName: newName)
                    editingSessionID = nil
                },
                onSelect: {
                    selectSession(session)
                },
                onRename: {
                    editingSessionID = session.id
                    draftSessionName = session.name
                },
                onBranch: { copyHistory in
                    let newSession = viewModel.branchSession(from: session, copyMessages: copyHistory)
                    viewModel.setCurrentSession(newSession)
                    focusOnLatest()
                },
                onMoveToFolder: { targetFolderID in
                    viewModel.moveSession(session, toFolderID: targetFolderID)
                },
                onDeleteLastMessage: {
                    viewModel.deleteLastMessage(for: session)
                },
                onDelete: {
                    sessionToDelete = session
                },
                onCancelRename: {
                    editingSessionID = nil
                    draftSessionName = session.name
                },
                onInfo: {
                    sessionInfo = SessionInfoPayload(
                        session: session,
                        messageCount: viewModel.messageCount(for: session),
                        isCurrent: session.id == viewModel.currentSession?.id
                    )
                },
                onSendToCompanion: {
                    syncManager.sendSessionToCompanion(sessionID: session.id)
                }
            )
        }
    }

    @ViewBuilder
    func searchResultRow(_ result: SessionHistorySearchResult) -> some View {
        if let session = viewModel.chatSessions.first(where: { $0.id == result.sessionID }) {
            Button {
                selectSession(session, messageOrdinal: result.messageOrdinal)
            } label: {
                SessionListRowContent(
                    title: searchResultTitle(for: result),
                    subtitle: result.match.preview,
                    footnote: nil,
                    isCurrent: session.id == viewModel.currentSession?.id,
                    isRunning: viewModel.runningSessionIDs.contains(session.id)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    func folderLabel(for folder: SessionFolder) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(folder.name)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                }
                .etFont(.system(size: 16, weight: .medium))

                let count = recursiveSessionCount(in: folder.id)
                Text(String(format: NSLocalizedString("%d 个会话", comment: ""), count))
                    .etFont(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    func toggleBatchMode() {
        isBatchSelecting.toggle()
        if !isBatchSelecting {
            selectedSessionIDs.removeAll()
            selectedFolderIDs.removeAll()
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
            viewModel.moveSession(session, toFolderID: folderID)
        }
        for folder in selectedFolders {
            viewModel.moveSessionFolder(folder, toParentID: folderID)
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
        let sessions = selectedSessions
        let folders = selectedFolders
        guard !sessions.isEmpty || !folders.isEmpty else { return }
        if !sessions.isEmpty {
            viewModel.deleteSessions(sessions)
        }
        folders.forEach { viewModel.deleteSessionFolder($0) }
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

    func normalizeSessionPageIndex() {
        let maxIndex = max(totalSessionPages - 1, 0)
        if sessionPageIndex > maxIndex {
            sessionPageIndex = maxIndex
        }
        if sessionPageIndex < 0 {
            sessionPageIndex = 0
        }
    }

    func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        sessionPageIndex -= 1
    }

    func goToNextPage() {
        guard canGoToNextPage else { return }
        sessionPageIndex += 1
        unlockConversationArchaeologistIfNeeded()
    }

    func normalizeSearchResultPageIndex() {
        let maxIndex = max(totalSearchResultPages - 1, 0)
        if searchResultPageIndex > maxIndex {
            searchResultPageIndex = maxIndex
        }
        if searchResultPageIndex < 0 {
            searchResultPageIndex = 0
        }
    }

    func goToPreviousActivePage() {
        if isSearchActive {
            guard canGoToPreviousSearchResultPage else { return }
            searchResultPageIndex -= 1
            return
        }
        goToPreviousPage()
    }

    func goToNextActivePage() {
        if isSearchActive {
            guard canGoToNextSearchResultPage else { return }
            searchResultPageIndex += 1
            return
        }
        goToNextPage()
    }

    func unlockConversationArchaeologistIfNeeded() {
        guard AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(
            totalSessions: totalDirectSessionCount,
            pageIndex: sessionPageIndex,
            totalPages: totalSessionPages
        ) else { return }

        Task {
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .conversationArchaeologist)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: .conversationArchaeologist)
        }
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
        let sessions = viewModel.chatSessions
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
            guard visited.insert(current).inserted else {
                return false
            }
            cursor = folderByID[current]?.parentID
        }
        return false
    }

    func descendantFolderIDs(rootID: UUID) -> Set<UUID> {
        var collected: Set<UUID> = [rootID]
        var queue: [UUID] = [rootID]

        while let current = queue.first {
            queue.removeFirst()
            let children = viewModel.sessionFolders.filter { normalizedParentID(of: $0) == current }
            for child in children where collected.insert(child.id).inserted {
                queue.append(child.id)
            }
        }

        return collected
    }

    func recursiveSessionCount(in folderID: UUID) -> Int {
        let descendants = descendantFolderIDs(rootID: folderID)
        return viewModel.chatSessions.filter { session in
            guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID)
        }.count
    }

    func folderDisplayPath(_ folder: SessionFolder) -> String {
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

    func folderLocationSummary(for session: ChatSession) -> String {
        guard let folderID = normalizedFolderID(of: session),
              let folder = folderByID[folderID] else {
            return NSLocalizedString("位置：未分类", comment: "")
        }
        return String(format: NSLocalizedString("位置：%@", comment: ""), folderDisplayPath(folder))
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
        return "“\(result.sessionName)” \(sourceLabel(for: result.match.source))"
    }

    func scheduleSearch(for query: String) {
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil

        let normalized = SessionHistorySearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else {
            searchHits = [:]
            isSearching = false
            searchResultPageIndex = 0
            return
        }

        isSearching = true
        latestSearchToken += 1
        let searchToken = latestSearchToken
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
                guard searchToken == latestSearchToken else { return }
                searchHits = hits
                isSearching = false
                pendingSearchWorkItem = nil
            }
        }

        pendingSearchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func presentCreateFolder(parentID: UUID?) {
        createFolderParentID = parentID
        createFolderName = ""
        isShowingCreateFolderAlert = true
    }

    func startRenaming(_ folder: SessionFolder) {
        folderToRename = folder
        renameFolderName = folder.name
        isShowingRenameFolderAlert = true
    }

    /// 选择会话时检测是否为 Ghost Session
    func selectSession(_ session: ChatSession, messageOrdinal: Int? = nil) {
        if session.isTemporary {
            if let messageOrdinal {
                viewModel.requestMessageJump(sessionID: session.id, messageOrdinal: messageOrdinal)
            } else {
                viewModel.clearPendingMessageJumpTarget()
            }
            viewModel.setCurrentSession(session)
            dismiss()
            NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
            return
        }

        if !Persistence.sessionDataExists(sessionID: session.id) {
            ghostSession = session
            showGhostSessionAlert = true
        } else {
            if let messageOrdinal {
                viewModel.requestMessageJump(sessionID: session.id, messageOrdinal: messageOrdinal)
            } else {
                viewModel.clearPendingMessageJumpTarget()
            }
            viewModel.setCurrentSession(session)
            dismiss()
            NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
        }
    }

    func focusOnLatest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editingSessionID = viewModel.currentSession?.id
            draftSessionName = viewModel.currentSession?.name ?? ""
        }
    }
}
