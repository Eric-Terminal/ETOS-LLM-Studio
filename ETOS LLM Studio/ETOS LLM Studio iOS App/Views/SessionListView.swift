// ============================================================================
// SessionListView.swift
// ============================================================================
// 会话管理界面 (iOS)
// - 展示所有会话并支持快速切换
// - 支持内联重命名、分支与删除
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct SessionListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var syncManager: WatchSyncManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var editingSessionID: UUID?
    @State private var draftName: String = ""
    @State private var sessionToDelete: ChatSession?
    @State private var sessionInfo: SessionInfoPayload?
    @State private var showGhostSessionAlert = false
    @State private var ghostSession: ChatSession?
    @State private var searchText: String = ""
    @State private var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State private var isSearching: Bool = false
    @State private var latestSearchToken: Int = 0
    @State private var pendingSearchWorkItem: DispatchWorkItem?
    
    var body: some View {
        let normalizedQuery = SessionHistorySearchSupport.normalizedQuery(searchText)
        let displayedSessions = normalizedQuery.isEmpty
            ? viewModel.chatSessions
            : viewModel.chatSessions.filter { searchHits[$0.id] != nil }

        List {
            Section {
                Button {
                    viewModel.createNewSession()
                    focusOnLatest()
                    dismiss()
                    NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
                } label: {
                    Label("开启新对话", systemImage: "plus.circle.fill")
                }
            }
            
            Section("会话") {
                if !normalizedQuery.isEmpty {
                    if isSearching {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在搜索历史会话…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("匹配 \(displayedSessions.count) / \(viewModel.chatSessions.count) 个会话")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if displayedSessions.isEmpty {
                    Text(normalizedQuery.isEmpty ? "暂无会话。" : (isSearching ? "正在搜索，请稍候…" : "未找到匹配的历史会话。"))
                        .foregroundStyle(.secondary)
                }

                ForEach(displayedSessions) { session in
                    SessionRow(
                        session: session,
                        isCurrent: session.id == viewModel.currentSession?.id,
                        isEditing: editingSessionID == session.id,
                        draftName: editingSessionID == session.id ? $draftName : .constant(session.name),
                        searchSummary: searchSummary(for: session, in: searchHits, queryActive: !normalizedQuery.isEmpty),
                        onCommit: { newName in
                            viewModel.updateSessionName(session, newName: newName)
                            editingSessionID = nil
                        },
                        onSelect: {
                            selectSession(session)
                        },
                        onRename: {
                            editingSessionID = session.id
                            draftName = session.name
                        },
                        onBranch: { copyHistory in
                            let newSession = viewModel.branchSession(from: session, copyMessages: copyHistory)
                            viewModel.setCurrentSession(newSession)
                            focusOnLatest()
                        },
                        onDeleteLastMessage: {
                            viewModel.deleteLastMessage(for: session)
                        },
                        onDelete: {
                            sessionToDelete = session
                        },
                        onCancelRename: {
                            editingSessionID = nil
                            draftName = session.name
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
                .onDelete { indexSet in
                    if let index = indexSet.first {
                        sessionToDelete = displayedSessions[index]
                    }
                }
            }
        }
        .navigationTitle("会话管理")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("搜索会话标题或消息")
        )
        .onAppear {
            scheduleSearch(for: searchText)
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onChange(of: viewModel.chatSessions) { _, _ in
            scheduleSearch(for: searchText)
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            scheduleSearch(for: searchText)
        }
        .onChange(of: viewModel.allMessagesForSession) { _, _ in
            scheduleSearch(for: searchText)
        }
        .onDisappear {
            pendingSearchWorkItem?.cancel()
            pendingSearchWorkItem = nil
        }
        .alert("确认删除会话", isPresented: Binding(
            get: { sessionToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    sessionToDelete = nil
                }
            }
        )) {
            Button("删除", role: .destructive) {
                if let session = sessionToDelete {
                    viewModel.deleteSessions([session])
                }
                sessionToDelete = nil
            }
            Button("取消", role: .cancel) {
                sessionToDelete = nil
            }
        } message: {
            Text("删除后所有消息也将被移除，操作不可恢复。")
        }
        .sheet(item: $sessionInfo) { info in
            SessionInfoSheet(payload: info)
        }
        .alert("发现幽灵会话", isPresented: $showGhostSessionAlert) {
            Button("删除幽灵", role: .destructive) {
                if let session = ghostSession {
                    viewModel.deleteSessions([session])
                }
                ghostSession = nil
            }
            Button("稍后处理", role: .cancel) {
                ghostSession = nil
            }
        } message: {
            Text("这个会话的消息文件已经丢失了，只剩下一个空壳在这里游荡。\n\n要帮它超度吗？")
        }
    }
    
    /// 选择会话时检测是否为 Ghost Session
    private func selectSession(_ session: ChatSession) {
        if session.isTemporary {
            viewModel.setCurrentSession(session)
            dismiss()
            return
        }

        // 检查会话数据文件是否存在（兼容 V3 与 legacy）
        if !Persistence.sessionDataExists(sessionID: session.id) {
            // 发现幽灵会话！
            ghostSession = session
            showGhostSessionAlert = true
        } else {
            viewModel.setCurrentSession(session)
            dismiss()
        }
    }
    
    private func focusOnLatest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editingSessionID = viewModel.currentSession?.id
            draftName = viewModel.currentSession?.name ?? ""
        }
    }

    private func searchSummary(
        for session: ChatSession,
        in hits: [UUID: SessionHistorySearchHit],
        queryActive: Bool
    ) -> String? {
        guard queryActive, let hit = hits[session.id] else { return nil }
        return "\(sourceLabel(for: hit.source))：\(hit.preview)"
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
}

// MARK: - Row

private struct SessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let searchSummary: String?
    
    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onSendToCompanion: () -> Void
    
    @FocusState private var focused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField("会话名称", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        commit()
                    }
                    .onAppear { focused = true }
                
                HStack {
                    Button("保存") {
                        commit()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("取消") {
                        onCancelRename()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .font(.headline)
                        if let searchSummary, !searchSummary.isEmpty {
                            Text(searchSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.footnote.bold())
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("切换到此会话", systemImage: "checkmark.circle")
            }
            
            Button {
                onRename()
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            
            Button {
                onBranch(false)
            } label: {
                Label("创建提示词分支", systemImage: "arrow.branch")
            }
            
            Button {
                onBranch(true)
            } label: {
                Label("复制历史创建分支", systemImage: "arrow.triangle.branch")
            }
            
            Button {
                onDeleteLastMessage()
            } label: {
                Label("删除最后一条消息", systemImage: "delete.backward")
            }
            
            Button {
                onInfo()
            } label: {
                Label("查看会话信息", systemImage: "info.circle")
            }

            Button {
                onSendToCompanion()
            } label: {
                Label("发送到 Apple Watch", systemImage: "applewatch")
            }
            .disabled(session.isTemporary)
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除会话", systemImage: "trash")
            }
        }
    }
    
    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

// MARK: - Session Info

/// 会话信息弹窗的数据载体，用于隔离 UI 与业务模型
private struct SessionInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

/// 会话信息弹窗，展示基础状态与唯一标识
private struct SessionInfoSheet: View {
    let payload: SessionInfoPayload
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("会话概览") {
                    LabeledContent("名称") {
                        Text(payload.session.name)
                    }
                    LabeledContent("状态") {
                        Text(payload.isCurrent ? "当前会话" : "历史会话")
                            .foregroundStyle(payload.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent("消息数量") {
                        Text(String(format: NSLocalizedString("%d 条", comment: ""), payload.messageCount))
                    }
                }
                
                if let topic = payload.session.topicPrompt, !topic.isEmpty {
                    Section("主题提示") {
                        Text(topic)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let enhanced = payload.session.enhancedPrompt, !enhanced.isEmpty {
                    Section("增强提示词") {
                        Text(enhanced)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("唯一标识") {
                    Text(payload.session.id.uuidString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("会话信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
