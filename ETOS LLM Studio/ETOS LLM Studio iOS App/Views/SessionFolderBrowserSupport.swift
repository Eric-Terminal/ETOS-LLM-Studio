// ============================================================================
// SessionFolderBrowserSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 iOS 会话文件夹浏览器的无限滚动、搜索、路径与选择辅助逻辑。
// ============================================================================

import Foundation
import ETOSCore
import SwiftUI

extension SessionFolderBrowserView {
    func resetLoadedDirectSessions() {
        pendingLoadMoreSessionsTask?.cancel()
        pendingLoadMoreSessionsTask = nil
        isLoadingMoreSessions = false
        loadedDirectSessions = []
        appendInitialDirectSessionsPage()
    }

    func resetLoadedSearchResultItems() {
        pendingLoadMoreSearchResultsTask?.cancel()
        pendingLoadMoreSearchResultsTask = nil
        isLoadingMoreSearchResults = false
        loadedSearchResultItems = []
        appendInitialSearchResultItemsPage()
    }

    func appendInitialDirectSessionsPage() {
        let source = directSessions
        let end = min(maxSessionsPerPage, source.count)
        guard end > 0 else { return }
        loadedDirectSessions = Array(source.prefix(end))
    }

    func appendInitialSearchResultItemsPage() {
        let source = searchResultItems
        let end = min(maxSessionsPerPage, source.count)
        guard end > 0 else { return }
        loadedSearchResultItems = Array(source.prefix(end))
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

            let source = directSessions
            let start = loadedDirectSessions.count
            let end = min(start + maxSessionsPerPage, source.count)
            if start < end {
                loadedDirectSessions.append(contentsOf: source[start..<end])
            }
            isLoadingMoreSessions = false
            pendingLoadMoreSessionsTask = nil
        }
    }

    func scheduleNextSearchResultItemsPage() {
        guard !isLoadingMoreSearchResults, hasMoreSearchResults, pendingLoadMoreSearchResultsTask == nil else { return }
        isLoadingMoreSearchResults = true
        pendingLoadMoreSearchResultsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else {
                isLoadingMoreSearchResults = false
                pendingLoadMoreSearchResultsTask = nil
                return
            }

            let source = searchResultItems
            let start = loadedSearchResultItems.count
            let end = min(start + maxSessionsPerPage, source.count)
            if start < end {
                loadedSearchResultItems.append(contentsOf: source[start..<end])
            }
            isLoadingMoreSearchResults = false
            pendingLoadMoreSearchResultsTask = nil
        }
    }

    func syncLoadedDirectSessionsWithSource() {
        pendingLoadMoreSessionsTask?.cancel()
        pendingLoadMoreSessionsTask = nil
        isLoadingMoreSessions = false
        let loadedCount = min(max(loadedDirectSessions.count, maxSessionsPerPage), directSessions.count)
        loadedDirectSessions = Array(directSessions.prefix(loadedCount))
    }

    func syncLoadedSearchResultItemsWithSource() {
        pendingLoadMoreSearchResultsTask?.cancel()
        pendingLoadMoreSearchResultsTask = nil
        isLoadingMoreSearchResults = false
        let source = searchResultItems
        let loadedCount = min(max(loadedSearchResultItems.count, maxSessionsPerPage), source.count)
        loadedSearchResultItems = Array(source.prefix(loadedCount))
    }

    func loadMoreDirectSessionsIfNeeded(currentID: UUID) {
        guard loadedDirectSessions.suffix(infiniteScrollTriggerRemainingCount).contains(where: { $0.id == currentID }) else { return }
        scheduleNextDirectSessionsPage()
    }

    func loadMoreSearchResultItemsIfNeeded(currentID: String) {
        guard loadedSearchResultItems.suffix(infiniteScrollTriggerRemainingCount).contains(where: { $0.id == currentID }) else { return }
        scheduleNextSearchResultItemsPage()
    }

    func unlockConversationArchaeologistIfNeeded(for session: ChatSession) {
        guard AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(
            selectedSession: session,
            sessions: viewModel.chatSessions
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
            return descendants.contains(assignedFolderID) && sessionMatchesTagFilter(session)
        }.count
    }

    func sessionTags(for session: ChatSession) -> [SessionTag] {
        let tagByID = viewModel.sessionTags.reduce(into: [UUID: SessionTag]()) { result, tag in
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
        return viewModel.chatSessions.contains { session in
            guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID) && sessionMatchesTagFilter(session)
        }
    }

    var tagFilterSummary: String {
        selectedTagFilters.map(\.name).joined(separator: NSLocalizedString("、", comment: "List separator"))
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
            isLoadingMoreSearchResults = false
            loadedSearchResultItems = []
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
                resetLoadedSearchResultItems()
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

    /// 选择会话时检测是否为 Ghost Session。
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
            unlockConversationArchaeologistIfNeeded(for: session)
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

    var loadingMoreFooter: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(NSLocalizedString("正在加载", comment: ""))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}
