// ============================================================================
// SessionListViewSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话历史列表辅助视图
// ============================================================================

import Foundation
import Shared
import SwiftUI

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
    let tags: [SessionTag]
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .etFont(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    WatchSessionTagInlineList(tags: tags)
                }
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

    @Environment(\.dismiss) private var dismiss

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

struct WatchSessionSearchView: View {
    let sessions: [ChatSession]
    let folders: [SessionFolder]
    let currentSessionID: UUID?
    let onSelect: (ChatSession, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var committedSearchText: String = ""
    @State private var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State private var isSearching: Bool = false
    @State private var latestSearchToken: Int = 0
    @State private var pendingSearchWorkItem: DispatchWorkItem?
    @State private var loadedSearchResults: [SessionHistorySearchResult] = []
    @State private var isLoadingMoreResults = false

    private let maxResultsPerPage = 50
    private let infiniteScrollTriggerRemainingCount = 5

    private var normalizedQuery: String {
        SessionHistorySearchSupport.normalizedQuery(committedSearchText)
    }

    private var searchResults: [SessionHistorySearchResult] {
        guard !normalizedQuery.isEmpty else { return [] }
        return SessionHistorySearchSupport.flattenedResults(
            sessions: sessions,
            hits: searchHits
        )
    }

    private var pagedSearchResults: [SessionHistorySearchResult] {
        loadedSearchResults
    }

    private var hasMoreSearchResults: Bool {
        loadedSearchResults.count < searchResults.count
    }

    private var shouldShowLoadingMoreFooter: Bool {
        isLoadingMoreResults || hasMoreSearchResults
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
                            .onAppear {
                                loadMoreResultsIfNeeded(currentID: result.id)
                            }
                    }

                    if shouldShowLoadingMoreFooter {
                        loadingMoreFooter
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("搜索会话", comment: ""))
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
    private func resultRow(_ result: SessionHistorySearchResult) -> some View {
        Button {
            guard let session = sessions.first(where: { $0.id == result.sessionID }) else { return }
            onSelect(session, result.messageOrdinal)
            dismiss()
        } label: {
            WatchSessionSearchResultRowContent(
                title: searchResultTitle(for: result),
                preview: result.match.preview,
                isSelected: result.sessionID == currentSessionID
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchResultTitle(for result: SessionHistorySearchResult) -> String {
        if let messageOrdinal = result.messageOrdinal {
            return String(format: NSLocalizedString("“%@” 第%d条", comment: ""), result.sessionName, messageOrdinal)
        }
        return "“\(result.sessionName)” \(sourceLabel(for: result.match.source))"
    }

    private func sourceLabel(for source: SessionHistorySearchHitSource) -> String {
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

    private func submitSearch() {
        let committed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        committedSearchText = committed
        isLoadingMoreResults = false
        loadedSearchResults = []
        scheduleSearch(for: committed)
    }

    private func clearSearch() {
        searchText = ""
        committedSearchText = ""
        isLoadingMoreResults = false
        loadedSearchResults = []
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil
        searchHits = [:]
        isSearching = false
    }

    private func scheduleSearch(for query: String) {
        pendingSearchWorkItem?.cancel()
        pendingSearchWorkItem = nil

        let normalized = SessionHistorySearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else {
            searchHits = [:]
            isSearching = false
            isLoadingMoreResults = false
            loadedSearchResults = []
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
                resetLoadedSearchResults()
                isSearching = false
                pendingSearchWorkItem = nil
            }
        }

        pendingSearchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func resetLoadedSearchResults() {
        isLoadingMoreResults = false
        loadedSearchResults = []
        appendNextSearchResultsPage()
    }

    private func appendNextSearchResultsPage() {
        guard !isLoadingMoreResults, hasMoreSearchResults else { return }
        isLoadingMoreResults = true

        let source = searchResults
        let start = loadedSearchResults.count
        let end = min(start + maxResultsPerPage, source.count)
        guard start < end else {
            isLoadingMoreResults = false
            return
        }
        loadedSearchResults.append(contentsOf: source[start..<end])
        DispatchQueue.main.async {
            isLoadingMoreResults = false
        }
    }

    private func loadMoreResultsIfNeeded(currentID: String) {
        guard loadedSearchResults.suffix(infiniteScrollTriggerRemainingCount).contains(where: { $0.id == currentID }) else { return }
        appendNextSearchResultsPage()
    }

    private var loadingMoreFooter: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(NSLocalizedString("正在加载", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WatchSessionSearchResultRowContent: View {
    let title: String
    let preview: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .etFont(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(preview)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SessionRowView: View {
    let session: ChatSession
    let isRunning: Bool
    @Binding var currentSession: ChatSession?
    @Binding var folders: [SessionFolder]
    let tags: [SessionTag]
    let sessionTags: [SessionTag]
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionToDelete: ChatSession?
    @Binding var showDeleteSessionConfirm: Bool

    let onSessionSelected: (ChatSession, Int?) -> Void
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let moveSessionToFolderAction: (ChatSession, UUID?) -> Void
    let setSessionTagsAction: (ChatSession, [UUID]) -> Void

    var body: some View {
        Button(action: { onSessionSelected(session, nil) }) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(content: session.name, uiFont: .preferredFont(forTextStyle: .headline))
                        .foregroundColor(.primary)
                        .allowsHitTesting(false)
                    WatchSessionTagInlineList(tags: sessionTags)
                }

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
                    tags: tags,
                    onDeleteLastMessage: { deleteLastMessageAction(session) },
                    onSendSessionToCompanion: { sendSessionToCompanionAction(session) },
                    onMoveSessionToFolder: { targetFolderID in
                        moveSessionToFolderAction(session, targetFolderID)
                    },
                    onSetTagIDs: { tagIDs in
                        setSessionTagsAction(session, tagIDs)
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
