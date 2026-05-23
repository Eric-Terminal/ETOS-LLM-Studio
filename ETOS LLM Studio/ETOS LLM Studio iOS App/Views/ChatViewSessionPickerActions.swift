// ============================================================================
// ChatViewSessionPickerActions.swift
// ============================================================================
// ETOS LLM Studio
//
// ChatView 会话选择器的无限滚动、搜索调度、行事件与跳转行为。
// ============================================================================

import Foundation
import SwiftUI
import Shared

extension ChatView {
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
        let end = min(sessionPickerMaxSessionsPerPage, viewModel.chatSessions.count)
        guard end > 0 else { return }
        loadedSessionPickerSessions = Array(viewModel.chatSessions.prefix(end))
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

            let start = loadedSessionPickerSessions.count
            let end = min(start + sessionPickerMaxSessionsPerPage, viewModel.chatSessions.count)
            if start < end {
                loadedSessionPickerSessions.append(contentsOf: viewModel.chatSessions[start..<end])
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
        let loadedCount = min(max(loadedSessionPickerSessions.count, sessionPickerMaxSessionsPerPage), viewModel.chatSessions.count)
        loadedSessionPickerSessions = Array(viewModel.chatSessions.prefix(loadedCount))
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

    func sessionPickerRow(_ session: ChatSession) -> some View {
        let isCurrent = session.id == viewModel.currentSession?.id
        let isEditing = editingSessionID == session.id
        let selectedFill = Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.12)

        return SessionPickerRow(
            session: session,
            isCurrent: isCurrent,
            isRunning: viewModel.runningSessionIDs.contains(session.id),
            isEditing: isEditing,
            draftName: isEditing ? $sessionDraftName : .constant(session.name),
            searchSummary: nil,
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
            onExport: { format, includeReasoning in
                exportSession(session, format: format, includeReasoning: includeReasoning)
            }
        )
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? selectedFill : Color.clear)
        )
    }

    func sessionPickerSearchResultRow(_ result: SessionHistorySearchResult) -> some View {
        let isCurrent = result.sessionID == viewModel.currentSession?.id
        let selectedFill = Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.12)

        return Button {
            if let session = viewModel.chatSessions.first(where: { $0.id == result.sessionID }) {
                selectSessionFromPicker(session, messageOrdinal: result.messageOrdinal)
            }
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: searchResultTitle(for: result),
                subtitle: result.match.preview,
                isSelected: isCurrent,
                titleUIFont: .systemFont(ofSize: 15, weight: .semibold),
                subtitleUIFont: .systemFont(ofSize: 12)
            )
            .foregroundColor(TelegramColors.navBarText)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? selectedFill : Color.clear)
        )
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
        dismissSessionPickerPanel()
    }
}
