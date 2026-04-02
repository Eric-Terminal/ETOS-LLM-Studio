// ============================================================================
// SessionListView.swift
// ============================================================================ 
// ETOS LLM Studio Watch App 会话历史列表视图
//
// 功能特性:
// - 显示所有历史会话
// - 支持会话选择、删除和更多操作（通过滑动菜单和详情面板）
// ============================================================================ 

import SwiftUI
import Foundation
import Shared

/// 会话历史列表视图
struct SessionListView: View {
    
    // MARK: - 绑定
    
    @Binding var sessions: [ChatSession]
    @Binding var currentSession: ChatSession?
    
    // MARK: - 操作
    
    let deleteAction: (IndexSet) -> Void
    let branchAction: (ChatSession, Bool) -> ChatSession?
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let onSessionSelected: (ChatSession) -> Void
    let updateSessionAction: (ChatSession) -> Void
    
    // MARK: - 状态
    
    @State private var showDeleteSessionConfirm: Bool = false
    @State private var sessionIndexToDelete: IndexSet?
    @State private var sessionToEdit: ChatSession?
    @State private var showBranchOptions: Bool = false
    @State private var sessionToBranch: ChatSession?
    @State private var showSessionSearch: Bool = false
    
    // MARK: - 视图主体
    
    var body: some View {
        List {
            if sessions.isEmpty {
                Text("暂无历史会话。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    SessionRowView(
                        session: session,
                        currentSession: $currentSession,
                        sessions: $sessions,
                        sessionToEdit: $sessionToEdit,
                        sessionToBranch: $sessionToBranch,
                        showBranchOptions: $showBranchOptions,
                        sessionIndexToDelete: $sessionIndexToDelete,
                        showDeleteSessionConfirm: $showDeleteSessionConfirm,
                        searchSummary: nil,
                        onSessionSelected: onSessionSelected,
                        deleteLastMessageAction: deleteLastMessageAction,
                        sendSessionToCompanionAction: sendSessionToCompanionAction
                    )
                }
            }
        }
        .navigationTitle("历史会话")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSessionSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("搜索会话")
            }
        }
        .navigationDestination(isPresented: $showSessionSearch) {
            WatchSessionSearchView(
                sessions: sessions,
                currentSessionID: currentSession?.id,
                onSelect: { session in
                    onSessionSelected(session)
                }
            )
        }
        .sheet(item: $sessionToEdit) {
            sessionToEdit in 
            if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionToEdit.id }) {
                let sessionBinding = $sessions[sessionIndex]
                EditSessionNameView(session: sessionBinding, onSave: { updatedSession in
                    updateSessionAction(updatedSession)
                })
            }
        }
        .confirmationDialog("确认删除", isPresented: $showDeleteSessionConfirm, titleVisibility: .visible) {
            Button("删除会话", role: .destructive) {
                if let indexSet = sessionIndexToDelete {
                    deleteAction(indexSet)
                }
                sessionIndexToDelete = nil
            }
            Button("取消", role: .cancel) {
                sessionIndexToDelete = nil
            }
        } message: {
            Text("您确定要删除这个会话及其所有消息吗？此操作无法撤销。")
        }
        .confirmationDialog("创建分支", isPresented: $showBranchOptions, titleVisibility: .visible) {
            Button("仅分支提示词") {
                if let session = sessionToBranch {
                    if let newSession = branchAction(session, false) {
                        onSessionSelected(newSession)
                    }
                    sessionToBranch = nil
                }
            }
            Button("分支提示词和对话记录") {
                if let session = sessionToBranch {
                    if let newSession = branchAction(session, true) {
                        onSessionSelected(newSession)
                    }
                    sessionToBranch = nil
                }
            }
            Button("取消", role: .cancel) {
                sessionToBranch = nil
            }
        } message: {
            if let session = sessionToBranch {
                Text(String(format: NSLocalizedString("从“%@”创建新的分支对话。", comment: ""), session.name))
            }
        }
    }
}

private struct WatchSessionSearchView: View {
    let sessions: [ChatSession]
    let currentSessionID: UUID?
    let onSelect: (ChatSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var committedSearchText: String = ""
    @State private var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State private var isSearching: Bool = false
    @State private var latestSearchToken: Int = 0
    @State private var pendingSearchWorkItem: DispatchWorkItem?

    private var normalizedQuery: String {
        SessionHistorySearchSupport.normalizedQuery(committedSearchText)
    }

    private var displayedSessions: [ChatSession] {
        guard !normalizedQuery.isEmpty else { return [] }
        return sessions.filter { searchHits[$0.id] != nil }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 6) {
                    TextField("搜索会话标题或消息", text: $searchText.watchKeyboardNewlineBinding())
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
                    Text("输入关键词后点完成开始搜索。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else if isSearching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在搜索历史会话…")
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("匹配 \(displayedSessions.count) / \(sessions.count) 个会话")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if normalizedQuery.isEmpty {
                    EmptyView()
                } else if displayedSessions.isEmpty {
                    Text("未找到匹配的历史会话。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedSessions) { session in
                        resultRow(session)
                    }
                }
            }
        }
        .navigationTitle("搜索会话")
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
    private func resultRow(_ session: ChatSession) -> some View {
        let summary = searchSummary(for: session)

        Button {
            onSelect(session)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .etFont(.footnote)
                        .lineLimit(1)

                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                    } else if let topic = session.topicPrompt, !topic.isEmpty {
                        Text(topic)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                if session.id == currentSessionID {
                    Image(systemName: "checkmark")
                        .etFont(.caption.bold())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchSummary(for session: ChatSession) -> String? {
        guard let hit = searchHits[session.id] else { return nil }
        let detailLines = hit.matches.map { match in
            let preview = compactSearchPreview(match.preview)
            if let messageOrdinal = match.messageOrdinal {
                return "• \(sourceLabel(for: match.source)) 第\(messageOrdinal)条：\(preview)"
            }
            return "• \(sourceLabel(for: match.source))：\(preview)"
        }
        if detailLines.count <= 1 {
            return detailLines.first
        }
        return "共命中 \(hit.matchCount) 处\n" + detailLines.joined(separator: "\n")
    }

    private func sourceLabel(for source: SessionHistorySearchHitSource) -> String {
        switch source {
        case .sessionName:
            return "标题"
        case .topicPrompt:
            return "主题提示"
        case .enhancedPrompt:
            return "增强提示词"
        case .userMessage:
            return "用户消息"
        case .assistantMessage:
            return "助手消息"
        case .systemMessage:
            return "系统消息"
        case .toolMessage:
            return "工具消息"
        case .errorMessage:
            return "错误消息"
        }
    }

    private func compactSearchPreview(_ text: String, maxLength: Int = 40) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    private func submitSearch() {
        let committed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        committedSearchText = committed
        scheduleSearch(for: committed)
    }

    private func clearSearch() {
        searchText = ""
        committedSearchText = ""
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
                isSearching = false
                pendingSearchWorkItem = nil
            }
        }

        pendingSearchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
}

// MARK: - 私有子视图

/// SessionListView 的列表行视图
/// 提取出来以简化主视图并避免编译器超时
private struct SessionRowView: View {
    
    // MARK: 属性与绑定
    
    let session: ChatSession
    @Binding var currentSession: ChatSession?
    @Binding var sessions: [ChatSession]
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionIndexToDelete: IndexSet?
    @Binding var showDeleteSessionConfirm: Bool
    let searchSummary: String?
    
    // MARK: 操作
    
    let onSessionSelected: (ChatSession) -> Void
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void

    // MARK: 视图主体
    
    var body: some View {
        Button(action: { onSessionSelected(session) }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    MarqueeText(content: session.name, uiFont: .preferredFont(forTextStyle: .headline))
                        .foregroundColor(.primary)
                        .allowsHitTesting(false) // 修复 Bug #1：让点击可以“穿透”滚动文本

                    if currentSession?.id == session.id {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }

                if let searchSummary, !searchSummary.isEmpty {
                    Text(searchSummary)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading) // 修复 Bug #2：让整行都能被点击
            .contentShape(Rectangle()) // 终极修复：明确按钮的可点击形状
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            NavigationLink {
                SessionActionsView(
                    session: session,
                    sessionToEdit: $sessionToEdit,
                    sessionToBranch: $sessionToBranch,
                    showBranchOptions: $showBranchOptions,
                    sessionIndexToDelete: $sessionIndexToDelete,
                    showDeleteSessionConfirm: $showDeleteSessionConfirm,
                    sessions: $sessions,
                    onDeleteLastMessage: { deleteLastMessageAction(session) },
                    onSendSessionToCompanion: { sendSessionToCompanionAction(session) }
                )
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
                sessionIndexToDelete = IndexSet(integer: index)
                showDeleteSessionConfirm = true
            } label: {
                Label("删除会话", systemImage: "trash")
            }
        }
    }
}
