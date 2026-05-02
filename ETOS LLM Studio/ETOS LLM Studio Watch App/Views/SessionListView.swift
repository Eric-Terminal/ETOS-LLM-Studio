// ============================================================================
// SessionListView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话历史列表视图
//
// 功能特性:
// - 文件夹与会话在同一列表混合展示
// - 顶部三点菜单支持新建文件夹与批量选中
// - 支持会话/文件夹批量移动、批量删除
// ============================================================================

import Foundation
import Shared
import SwiftUI

/// 会话历史列表视图
struct SessionListView: View {

    // MARK: - 绑定

    @Binding var sessions: [ChatSession]
    @Binding var folders: [SessionFolder]
    @Binding var currentSession: ChatSession?
    let runningSessionIDs: Set<UUID>

    // MARK: - 操作

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
    var createConversationAction: (() -> Void)? = nil

    var body: some View {
        SessionFolderBrowserView(
            folderID: nil,
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
            isRoot: true
        )
    }
}


struct SessionMergedEntryWithRank {
    let rank: Int
    let entry: SessionMergedEntry
}


enum SessionMergedEntry: Identifiable {
    case folder(SessionFolder)
    case session(ChatSession)

    var id: String {
        switch self {
        case .folder(let folder):
            return "folder-\(folder.id.uuidString)"
        case .session(let session):
            return "session-\(session.id.uuidString)"
        }
    }
}


struct SessionMoveTarget: Identifiable {
    let id: UUID
    let title: String
}


struct BatchSelectableFolderRow: View {
    let folder: SessionFolder
    let sessionCount: Int
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .etFont(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(String(format: NSLocalizedString("%d 个会话", comment: ""), sessionCount))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


struct BatchSelectableSessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(session.name)
                    .etFont(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


struct BatchMoveDestinationPickerView: View {
    let moveTargets: [SessionMoveTarget]
    let onSelect: (UUID?) -> Void

    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Button {
                onSelect(nil)
                dismiss()
            } label: {
                Label(NSLocalizedString("未分类", comment: ""), systemImage: "tray")
            }

            ForEach(moveTargets) { target in
                Button {
                    onSelect(target.id)
                    dismiss()
                } label: {
                    Label(target.title, systemImage: "folder")
                }
            }
        }
        .navigationTitle(NSLocalizedString("移动到文件夹", comment: ""))
    }
}


struct WatchPaginationBar: View {
    let summaryText: String
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let strokeColor: Color

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
            }
            .frame(minWidth: 30, minHeight: 30)
            .disabled(!canGoToPrevious)
            .accessibilityLabel(NSLocalizedString("上一页", comment: ""))

            Spacer(minLength: 1)

            summaryCapsule

            Spacer(minLength: 1)

            Button(action: onNext) {
                Image(systemName: "chevron.right")
            }
            .frame(minWidth: 30, minHeight: 30)
            .disabled(!canGoToNext)
            .accessibilityLabel(NSLocalizedString("下一页", comment: ""))
        }
        .frame(minHeight: 36)
    }

    @ViewBuilder
    var summaryCapsule: some View {
        let summaryContent = MarqueeText(
            content: summaryText,
            uiFont: .preferredFont(forTextStyle: .footnote),
            speed: 28,
            delay: 0.8,
            spacing: 24
        )
        .multilineTextAlignment(.center)
        .allowsHitTesting(false)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)

        if #available(watchOS 26.0, *) {
            summaryContent
                .glassEffect(.clear, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(strokeColor, lineWidth: 0.6)
                )
        } else {
            summaryContent
                .background(
                    Capsule()
                        .fill(Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(strokeColor, lineWidth: 0.6)
                )
        }
    }
}


struct WatchSessionSearchView: View {
    let sessions: [ChatSession]
    let folders: [SessionFolder]
    let currentSessionID: UUID?
    let onSelect: (ChatSession, Int?) -> Void

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State var searchText: String = ""
    @State var committedSearchText: String = ""
    @State var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State var isSearching: Bool = false
    @State var latestSearchToken: Int = 0
    @State var pendingSearchWorkItem: DispatchWorkItem?
    @State var resultPageIndex: Int = 0

    let maxResultsPerPage = 50

    var normalizedQuery: String {
        SessionHistorySearchSupport.normalizedQuery(committedSearchText)
    }

    var searchResults: [SessionHistorySearchResult] {
        guard !normalizedQuery.isEmpty else { return [] }
        return SessionHistorySearchSupport.flattenedResults(
            sessions: sessions,
            hits: searchHits
        )
    }

    var totalResultPages: Int {
        guard !searchResults.isEmpty else { return 1 }
        return ((searchResults.count - 1) / maxResultsPerPage) + 1
    }

    var shouldShowResultPagination: Bool {
        searchResults.count > maxResultsPerPage
    }

    var canGoToPreviousResultPage: Bool {
        resultPageIndex > 0
    }

    var canGoToNextResultPage: Bool {
        resultPageIndex + 1 < totalResultPages
    }

    var currentResultPageStartOrdinal: Int {
        guard !searchResults.isEmpty else { return 0 }
        return resultPageIndex * maxResultsPerPage + 1
    }

    var currentResultPageEndOrdinal: Int {
        guard !searchResults.isEmpty else { return 0 }
        return min((resultPageIndex + 1) * maxResultsPerPage, searchResults.count)
    }

    var paginationSummaryText: String {
        String(format: NSLocalizedString("当前显示%d-%d条结果(总共%d)", comment: ""), currentResultPageStartOrdinal, currentResultPageEndOrdinal, searchResults.count)
    }

    var paginationStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }

    var pagedSearchResults: [SessionHistorySearchResult] {
        guard !searchResults.isEmpty else { return [] }
        let start = min(resultPageIndex * maxResultsPerPage, searchResults.count)
        let end = min(start + maxResultsPerPage, searchResults.count)
        guard start < end else { return [] }
        return Array(searchResults[start..<end])
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 6) {
                    TextField(NSLocalizedString("搜索会话标题或消息", comment: ""), text: $searchText.watchKeyboardNewlineBinding())
                        .onSubmit {
                            submitSearch()
                        }
                    if !searchText.isEmpty {
                        Button {
                            clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                if normalizedQuery.isEmpty {
                    Text(NSLocalizedString("输入关键词后点完成开始搜索。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else if isSearching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(NSLocalizedString("正在搜索历史会话…", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), searchResults.count, searchHits.count))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if normalizedQuery.isEmpty {
                    EmptyView()
                } else if searchResults.isEmpty {
                    Text(NSLocalizedString("未找到匹配的搜索结果。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pagedSearchResults) { result in
                        resultRow(result)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("搜索会话", comment: ""))
        .safeAreaInset(edge: .bottom) {
            if !isSearching && shouldShowResultPagination {
                WatchPaginationBar(
                    summaryText: paginationSummaryText,
                    canGoToPrevious: canGoToPreviousResultPage,
                    canGoToNext: canGoToNextResultPage,
                    onPrevious: goToPreviousResultPage,
                    onNext: goToNextResultPage,
                    strokeColor: paginationStrokeColor
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
        }
        .onChange(of: sessions) { _, _ in
            guard !normalizedQuery.isEmpty else { return }
            scheduleSearch(for: committedSearchText)
        }
        .onDisappear {
            pendingSearchWorkItem?.cancel()
            pendingSearchWorkItem = nil
        }
    }

    @ViewBuilder
    func resultRow(_ result: SessionHistorySearchResult) -> some View {
        Button {
            guard let session = sessions.first(where: { $0.id == result.sessionID }) else { return }
            onSelect(session, result.messageOrdinal)
            dismiss()
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: searchResultTitle(for: result),
                subtitle: result.match.preview,
                isSelected: result.sessionID == currentSessionID,
                titleUIFont: .preferredFont(forTextStyle: .footnote),
                subtitleUIFont: .preferredFont(forTextStyle: .caption2)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func searchResultTitle(for result: SessionHistorySearchResult) -> String {
        if let messageOrdinal = result.messageOrdinal {
            return String(format: NSLocalizedString("“%@” 第%d条", comment: ""), result.sessionName, messageOrdinal)
        }
        return "“\(result.sessionName)” \(sourceLabel(for: result.match.source))"
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

    func normalizeResultPageIndex() {
        let maxIndex = max(totalResultPages - 1, 0)
        if resultPageIndex > maxIndex {
            resultPageIndex = maxIndex
        }
        if resultPageIndex < 0 {
            resultPageIndex = 0
        }
    }

    func goToPreviousResultPage() {
        guard canGoToPreviousResultPage else { return }
        resultPageIndex -= 1
    }

    func goToNextResultPage() {
        guard canGoToNextResultPage else { return }
        resultPageIndex += 1
    }

    func submitSearch() {
        let committed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        committedSearchText = committed
        resultPageIndex = 0
        scheduleSearch(for: committed)
    }

    func clearSearch() {
        searchText = ""
        committedSearchText = ""
        resultPageIndex = 0
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil
        searchHits = [:]
        isSearching = false
    }

    func scheduleSearch(for query: String) {
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil

        let normalized = SessionHistorySearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else {
            searchHits = [:]
            isSearching = false
            resultPageIndex = 0
            return
        }

        isSearching = true
        latestSearchToken += 1
        let searchToken = latestSearchToken
        let sessionSnapshot = sessions
        let querySnapshot = query

        let workItem = DispatchWorkItem {
            let hits = SessionHistorySearchSupport.searchHits(
                sessions: sessionSnapshot,
                query: querySnapshot,
                messageLoader: { sessionID in
                    Persistence.loadMessages(for: sessionID)
                }
            )
            DispatchQueue.main.async {
                guard searchToken == latestSearchToken else { return }
                searchHits = hits
                normalizeResultPageIndex()
                isSearching = false
                pendingSearchWorkItem = nil
            }
        }

        pendingSearchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
}


// MARK: - 私有子视图

struct SessionRowView: View {

    let session: ChatSession
    let isRunning: Bool
    @Binding var currentSession: ChatSession?
    @Binding var folders: [SessionFolder]
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionToDelete: ChatSession?
    @Binding var showDeleteSessionConfirm: Bool

    let onSessionSelected: (ChatSession, Int?) -> Void
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let moveSessionToFolderAction: (ChatSession, UUID?) -> Void

    var body: some View {
        Button(action: { onSessionSelected(session, nil) }) {
            HStack {
                MarqueeText(content: session.name, uiFont: .preferredFont(forTextStyle: .headline))
                    .foregroundColor(.primary)
                    .allowsHitTesting(false)

                Spacer()

                if isRunning {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                }

                if currentSession?.id == session.id {
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            NavigationLink {
                SessionActionsView(
                    session: session,
                    sessionToEdit: $sessionToEdit,
                    sessionToBranch: $sessionToBranch,
                    showBranchOptions: $showBranchOptions,
                    sessionToDelete: $sessionToDelete,
                    showDeleteSessionConfirm: $showDeleteSessionConfirm,
                    folders: $folders,
                    onDeleteLastMessage: { deleteLastMessageAction(session) },
                    onSendSessionToCompanion: { sendSessionToCompanionAction(session) },
                    onMoveSessionToFolder: { targetFolderID in
                        moveSessionToFolderAction(session, targetFolderID)
                    }
                )
            } label: {
                Label(NSLocalizedString("更多", comment: ""), systemImage: "ellipsis")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                sessionToDelete = session
                showDeleteSessionConfirm = true
            } label: {
                Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
            }
        }
    }
}
