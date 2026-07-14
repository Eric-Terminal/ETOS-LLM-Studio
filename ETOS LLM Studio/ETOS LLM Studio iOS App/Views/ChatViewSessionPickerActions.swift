// ============================================================================
// ChatViewSessionPickerActions.swift
// ============================================================================
// ETOS LLM Studio
//
// ChatView 会话选择器的无限滚动、搜索调度、行事件与跳转行为。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

extension ChatView {
    var sessionPickerFolderByID: [UUID: SessionFolder] {
        Dictionary(uniqueKeysWithValues: viewModel.sessionFolders.map { ($0.id, $0) })
    }

    var sessionPickerCurrentFolder: SessionFolder? {
        guard let folderID = sessionPickerFolderID else { return nil }
        return sessionPickerFolderByID[folderID]
    }

    var sessionPickerChildFolders: [SessionFolder] {
        viewModel.sessionFolders.filter {
            sessionPickerNormalizedParentID(of: $0) == sessionPickerFolderID
        }
    }

    var sessionPickerDirectSessions: [ChatSession] {
        viewModel.chatSessions.filter {
            sessionPickerNormalizedFolderID(of: $0) == sessionPickerFolderID
        }
    }

    var sessionPickerSearchSourceSessions: [ChatSession] {
        viewModel.chatSessions
    }

    var sessionPickerSessionOrderByID: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: viewModel.chatSessions.enumerated().map { ($1.id, $0) })
    }

    var sessionPickerMergedEntries: [SessionMergedEntry] {
        let folders = sessionPickerChildFolders.map {
            SessionMergedEntryWithRank(
                rank: sessionPickerRecentActivityIndex(for: $0.id),
                entry: .folder($0)
            )
        }
        let sessions = loadedSessionPickerSessions.map {
            SessionMergedEntryWithRank(
                rank: sessionPickerSessionOrderByID[$0.id] ?? .max,
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

    var sessionPickerKnownTagByID: [UUID: SessionTag] {
        let systemTags = SessionTagColor.allCases.map {
            SessionTag.systemColorTag(for: $0, updatedAt: Date(timeIntervalSince1970: 0))
        }
        return (systemTags + viewModel.sessionTags).reduce(into: [UUID: SessionTag]()) { result, tag in
            result[tag.id] = tag
        }
    }

    func resetSessionPickerLoadedSessions() {
        pendingLoadMoreSessionPickerSessionsTask?.cancel()
        pendingLoadMoreSessionPickerSessionsTask = nil
        isLoadingMoreSessionPickerSessions = false
        loadedSessionPickerSessions = []
        appendInitialSessionPickerSessionsPage()
    }

    func resetSessionPickerLoadedSearchResults() {
        pendingLoadMoreSessionPickerSearchResultsTask?.cancel()
        pendingLoadMoreSessionPickerSearchResultsTask = nil
        isLoadingMoreSessionPickerSearchResults = false
        loadedSessionPickerSearchResults = []
        appendInitialSessionPickerSearchResultsPage()
    }

    func appendInitialSessionPickerSessionsPage() {
        let source = sessionPickerDirectSessions
        let end = min(sessionPickerMaxSessionsPerPage, source.count)
        guard end > 0 else { return }
        loadedSessionPickerSessions = Array(source.prefix(end))
    }

    func appendInitialSessionPickerSearchResultsPage() {
        let results = sessionPickerSearchResults
        let end = min(sessionPickerMaxSessionsPerPage, results.count)
        guard end > 0 else { return }
        loadedSessionPickerSearchResults = Array(results.prefix(end))
    }

    func scheduleNextSessionPickerSessionsPage() {
        guard !isLoadingMoreSessionPickerSessions,
              hasMoreSessionPickerSessions,
              pendingLoadMoreSessionPickerSessionsTask == nil else { return }
        isLoadingMoreSessionPickerSessions = true
        pendingLoadMoreSessionPickerSessionsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else {
                isLoadingMoreSessionPickerSessions = false
                pendingLoadMoreSessionPickerSessionsTask = nil
                return
            }

            let source = sessionPickerDirectSessions
            let start = loadedSessionPickerSessions.count
            let end = min(start + sessionPickerMaxSessionsPerPage, source.count)
            if start < end {
                loadedSessionPickerSessions.append(contentsOf: source[start..<end])
            }
            isLoadingMoreSessionPickerSessions = false
            pendingLoadMoreSessionPickerSessionsTask = nil
        }
    }

    func scheduleNextSessionPickerSearchResultsPage() {
        guard !isLoadingMoreSessionPickerSearchResults,
              hasMoreSessionPickerSearchResults,
              pendingLoadMoreSessionPickerSearchResultsTask == nil else { return }
        isLoadingMoreSessionPickerSearchResults = true
        pendingLoadMoreSessionPickerSearchResultsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else {
                isLoadingMoreSessionPickerSearchResults = false
                pendingLoadMoreSessionPickerSearchResultsTask = nil
                return
            }

            let results = sessionPickerSearchResults
            let start = loadedSessionPickerSearchResults.count
            let end = min(start + sessionPickerMaxSessionsPerPage, results.count)
            if start < end {
                loadedSessionPickerSearchResults.append(contentsOf: results[start..<end])
            }
            isLoadingMoreSessionPickerSearchResults = false
            pendingLoadMoreSessionPickerSearchResultsTask = nil
        }
    }

    func syncLoadedSessionPickerSessionsWithSource() {
        pendingLoadMoreSessionPickerSessionsTask?.cancel()
        pendingLoadMoreSessionPickerSessionsTask = nil
        isLoadingMoreSessionPickerSessions = false
        let source = sessionPickerDirectSessions
        let loadedCount = min(max(loadedSessionPickerSessions.count, sessionPickerMaxSessionsPerPage), source.count)
        loadedSessionPickerSessions = Array(source.prefix(loadedCount))
    }

    func syncLoadedSessionPickerSearchResultsWithSource() {
        pendingLoadMoreSessionPickerSearchResultsTask?.cancel()
        pendingLoadMoreSessionPickerSearchResultsTask = nil
        isLoadingMoreSessionPickerSearchResults = false
        let results = sessionPickerSearchResults
        let loadedCount = min(max(loadedSessionPickerSearchResults.count, sessionPickerMaxSessionsPerPage), results.count)
        loadedSessionPickerSearchResults = Array(results.prefix(loadedCount))
    }

    func loadMoreSessionPickerItemsIfNeeded(currentID: String, queryActive: Bool) {
        if queryActive {
            guard loadedSessionPickerSearchResults.suffix(sessionPickerInfiniteScrollTriggerRemainingCount).contains(where: { $0.id == currentID }) else { return }
            scheduleNextSessionPickerSearchResultsPage()
            return
        }

        guard let sessionID = UUID(uuidString: currentID) else { return }
        guard loadedSessionPickerSessions.suffix(sessionPickerInfiniteScrollTriggerRemainingCount).contains(where: { $0.id == sessionID }) else { return }
        scheduleNextSessionPickerSessionsPage()
    }

    func cancelSessionPickerPagingTasks() {
        pendingLoadMoreSessionPickerSessionsTask?.cancel()
        pendingLoadMoreSessionPickerSessionsTask = nil
        pendingLoadMoreSessionPickerSearchResultsTask?.cancel()
        pendingLoadMoreSessionPickerSearchResultsTask = nil
        isLoadingMoreSessionPickerSessions = false
        isLoadingMoreSessionPickerSearchResults = false
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

    func sessionPickerLoadingMoreFooter(queryActive: Bool) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(NSLocalizedString("正在加载", comment: ""))
                .etFont(.system(size: 12, weight: .medium))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    func scheduleSessionPickerSearch(for query: String) {
        sessionPickerPendingSearchWorkItem?.cancel()
        sessionPickerPendingSearchWorkItem = nil

        let normalized = SessionHistorySearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else {
            sessionPickerSearchHits = [:]
            isSessionPickerSearching = false
            isLoadingMoreSessionPickerSearchResults = false
            loadedSessionPickerSearchResults = []
            return
        }

        isSessionPickerSearching = true
        sessionPickerLatestSearchToken += 1
        let searchToken = sessionPickerLatestSearchToken
        let sessionsSnapshot = sessionPickerSearchSourceSessions
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
                resetSessionPickerLoadedSearchResults()
                isSessionPickerSearching = false
                sessionPickerPendingSearchWorkItem = nil
            }
        }

        sessionPickerPendingSearchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func normalizeSessionPickerFolderSelection() {
        guard let folderID = sessionPickerFolderID else { return }
        if sessionPickerFolderByID[folderID] == nil {
            sessionPickerFolderID = nil
        }
    }

    func openSessionPickerFolder(_ folder: SessionFolder) {
        editingSessionID = nil
        sessionDraftName = ""
        sessionPickerFolderID = folder.id
    }

    func openSessionPickerParentFolder() {
        guard let currentFolder = sessionPickerCurrentFolder else {
            sessionPickerFolderID = nil
            return
        }
        sessionPickerFolderID = sessionPickerNormalizedParentID(of: currentFolder)
    }

    func createSessionFromPicker() {
        viewModel.createNewSession()
        if let folderID = sessionPickerFolderID,
           let session = viewModel.currentSession {
            viewModel.moveSession(session, toFolderID: folderID)
        }
        editingSessionID = nil
        sessionDraftName = ""
        dismissSessionPickerAfterSelection()
    }

    func sessionPickerEntryRow(_ entry: SessionMergedEntry) -> AnyView {
        switch entry {
        case .folder(let folder):
            return AnyView(sessionPickerFolderRow(folder))
        case .session(let session):
            return AnyView(
                sessionPickerRow(session)
                    .onAppear {
                        loadMoreSessionPickerItemsIfNeeded(currentID: session.id.uuidString, queryActive: false)
                    }
            )
        }
    }

    func sessionPickerFolderRow(_ folder: SessionFolder) -> some View {
        Button {
            openSessionPickerFolder(folder)
        } label: {
            SessionRowCard(isCurrent: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(folder.name)
                            .etFont(.system(size: 15.5, weight: .semibold))
                            .foregroundColor(TelegramColors.navBarText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }

                    Text(String(format: NSLocalizedString("%d 个会话", comment: ""), sessionPickerRecursiveSessionCount(in: folder.id)))
                        .etFont(.system(size: 12.5))
                        .foregroundColor(TelegramColors.navBarSubtitle)

                    SessionTagInlineList(tags: sessionPickerFolderTags(in: folder.id))
                }
            }
        }
        .buttonStyle(.plain)
    }

    func sessionPickerRow(_ session: ChatSession) -> some View {
        let isCurrent = session.id == viewModel.currentSession?.id
        let isEditing = editingSessionID == session.id

        return SessionPickerRow(
            session: session,
            isCurrent: isCurrent,
            isRunning: viewModel.runningSessionIDs.contains(session.id),
            isEditing: isEditing,
            draftName: isEditing ? $sessionDraftName : .constant(session.name),
            searchSummary: nil,
            tags: sessionPickerTags(for: session),
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
                dismissSessionPickerAfterSelection()
            },
            onCompress: {
                presentContextCompression(for: session)
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
            onExport: { format, includeReasoning, includeSystemPrompt in
                exportSession(
                    session,
                    format: format,
                    includeReasoning: includeReasoning,
                    includeSystemPrompt: includeSystemPrompt
                )
            }
        )
    }

    func presentContextCompression(for session: ChatSession) {
        guard !session.isTemporary else { return }
        if activeChatPickerSheet == .session {
            pendingContextCompressionSourceSession = session
            activeChatPickerSheet = nil
        } else {
            contextCompressionSourceSession = session
        }
    }

    func sessionPickerSearchResultRow(_ result: SessionHistorySearchResult) -> some View {
        let isCurrent = result.sessionID == viewModel.currentSession?.id
        let isRunning = viewModel.runningSessionIDs.contains(result.sessionID)

        return Button {
            if let session = viewModel.chatSessions.first(where: { $0.id == result.sessionID }) {
                selectSessionFromPicker(session, messageOrdinal: result.messageOrdinal)
            }
        } label: {
            SessionRowCard(isCurrent: isCurrent) {
                SessionSearchResultRowContent(
                    title: searchResultTitle(for: result),
                    preview: result.match.preview,
                    isCurrent: isCurrent,
                    isRunning: isRunning,
                    titleColor: TelegramColors.navBarText,
                    previewColor: .secondary
                )
            }
        }
        .buttonStyle(.plain)
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
            dismissSessionPickerAfterSelection()
            return
        }

        if !Persistence.sessionDataExists(sessionID: session.id) {
            ghostSession = session
            showGhostSessionAlert = true
        } else {
            unlockConversationArchaeologistIfNeeded(for: session)
            editingSessionID = nil
            if let messageOrdinal {
                viewModel.requestMessageJump(sessionID: session.id, messageOrdinal: messageOrdinal)
            } else {
                viewModel.clearPendingMessageJumpTarget()
            }
            viewModel.setCurrentSession(session)
            dismissSessionPickerAfterSelection()
        }
    }

    func dismissSessionPickerAfterSelection() {
        if usesLandscapeSessionSidebar {
            return
        }
        dismissSessionPicker()
    }

    func sessionPickerNormalizedFolderID(of session: ChatSession) -> UUID? {
        guard let folderID = session.folderID else { return nil }
        return sessionPickerFolderByID[folderID] == nil ? nil : folderID
    }

    func sessionPickerNormalizedParentID(of folder: SessionFolder) -> UUID? {
        guard let parentID = folder.parentID else { return nil }
        return sessionPickerFolderByID[parentID] == nil ? nil : parentID
    }

    func sessionPickerFolderHierarchyContains(descendantFolderID: UUID, ancestorFolderID: UUID) -> Bool {
        var cursor: UUID? = descendantFolderID
        var visited = Set<UUID>()
        while let current = cursor {
            if current == ancestorFolderID {
                return true
            }
            guard visited.insert(current).inserted else { return false }
            cursor = sessionPickerFolderByID[current]?.parentID
        }
        return false
    }

    func sessionPickerDescendantFolderIDs(rootID: UUID) -> Set<UUID> {
        var collected: Set<UUID> = [rootID]
        var queue: [UUID] = [rootID]

        while let current = queue.first {
            queue.removeFirst()
            let children = viewModel.sessionFolders.filter { sessionPickerNormalizedParentID(of: $0) == current }
            for child in children where collected.insert(child.id).inserted {
                queue.append(child.id)
            }
        }

        return collected
    }

    func sessionPickerRecentActivityIndex(for folderID: UUID) -> Int {
        for (index, session) in viewModel.chatSessions.enumerated() {
            guard let assignedFolderID = sessionPickerNormalizedFolderID(of: session) else { continue }
            if sessionPickerFolderHierarchyContains(descendantFolderID: assignedFolderID, ancestorFolderID: folderID) {
                return index
            }
        }
        return .max
    }

    func sessionPickerRecursiveSessionCount(in folderID: UUID) -> Int {
        let descendants = sessionPickerDescendantFolderIDs(rootID: folderID)
        return viewModel.chatSessions.filter { session in
            guard let assignedFolderID = sessionPickerNormalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID)
        }.count
    }

    func sessionPickerTags(for session: ChatSession) -> [SessionTag] {
        let tagByID = sessionPickerKnownTagByID
        return session.tagIDs.compactMap { tagByID[$0] }
    }

    func sessionPickerFolderTags(in folderID: UUID) -> [SessionTag] {
        let descendants = sessionPickerDescendantFolderIDs(rootID: folderID)
        let tagByID = sessionPickerKnownTagByID
        var seen = Set<UUID>()
        var result: [SessionTag] = []

        for session in viewModel.chatSessions {
            guard let assignedFolderID = sessionPickerNormalizedFolderID(of: session),
                  descendants.contains(assignedFolderID) else { continue }
            for tagID in session.tagIDs where seen.insert(tagID).inserted {
                guard let tag = tagByID[tagID] else { continue }
                result.append(tag)
                if result.count >= 6 {
                    return result
                }
            }
        }

        return result
    }

    func sessionPickerFolderPath(_ folder: SessionFolder) -> String {
        var parts: [String] = [folder.name]
        var cursor = folder.parentID
        var visited = Set<UUID>()

        while let current = cursor {
            guard visited.insert(current).inserted else { break }
            guard let parent = sessionPickerFolderByID[current] else { break }
            parts.append(parent.name)
            cursor = parent.parentID
        }

        return parts.reversed().joined(separator: " /")
    }
}
