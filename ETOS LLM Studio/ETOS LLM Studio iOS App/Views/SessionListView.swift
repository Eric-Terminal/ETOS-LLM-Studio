// ============================================================================
// SessionListView.swift
// ============================================================================
// 会话管理界面 (iOS)
// - 文件夹与会话合并展示，保持文件管理式浏览
// - 支持新建/重命名/删除文件夹
// - 支持批量选择会话并批量移动、批量删除
// ============================================================================

import Foundation
import Shared
import SwiftUI

struct SessionListView: View {
    let createConversationAction: (() -> Void)?

    init(createConversationAction: (() -> Void)? = nil) {
        self.createConversationAction = createConversationAction
    }

    var body: some View {
        SessionFolderBrowserView(
            folderID: nil,
            isRoot: true,
            createConversationAction: createConversationAction
        )
    }
}

private struct SessionFolderBrowserView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var syncManager: WatchSyncManager
    @Environment(\.dismiss) private var dismiss

    let folderID: UUID?
    let isRoot: Bool
    let createConversationAction: (() -> Void)?

    @State private var editingSessionID: UUID?
    @State private var draftSessionName: String = ""
    @State private var sessionToDelete: ChatSession?
    @State private var sessionInfo: SessionInfoPayload?
    @State private var showGhostSessionAlert = false
    @State private var ghostSession: ChatSession?

    @State private var createFolderParentID: UUID?
    @State private var createFolderName: String = ""
    @State private var isShowingCreateFolderAlert = false

    @State private var folderToRename: SessionFolder?
    @State private var renameFolderName: String = ""
    @State private var isShowingRenameFolderAlert = false

    @State private var folderToDelete: SessionFolder?

    @State private var isBatchSelecting = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var searchText: String = ""
    @State private var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State private var isSearching: Bool = false
    @State private var latestSearchToken: Int = 0
    @State private var pendingSearchWorkItem: DispatchWorkItem?
    @State private var sessionPageIndex: Int = 0
    @State private var searchResultPageIndex: Int = 0

    private let maxSessionsPerPage = 100

    private var folderByID: [UUID: SessionFolder] {
        Dictionary(uniqueKeysWithValues: viewModel.sessionFolders.map { ($0.id, $0) })
    }

    private var currentFolder: SessionFolder? {
        guard let folderID else { return nil }
        return folderByID[folderID]
    }

    private var childFolders: [SessionFolder] {
        viewModel.sessionFolders.filter { normalizedParentID(of: $0) == folderID }
    }

    private var directSessions: [ChatSession] {
        viewModel.chatSessions.filter { normalizedFolderID(of: $0) == folderID }
    }

    private var totalDirectSessionCount: Int {
        directSessions.count
    }

    private var totalSessionPages: Int {
        guard totalDirectSessionCount > 0 else { return 1 }
        return ((totalDirectSessionCount - 1) / maxSessionsPerPage) + 1
    }

    private var shouldShowPaginationBar: Bool {
        totalDirectSessionCount > maxSessionsPerPage
    }

    private var pagedDirectSessions: [ChatSession] {
        guard totalDirectSessionCount > 0 else { return [] }
        let start = min(sessionPageIndex * maxSessionsPerPage, totalDirectSessionCount)
        let end = min(start + maxSessionsPerPage, totalDirectSessionCount)
        guard start < end else { return [] }
        return Array(directSessions[start..<end])
    }

    private var sessionOrderByID: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: viewModel.chatSessions.enumerated().map { ($1.id, $0) })
    }

    private var mergedEntries: [SessionMergedEntry] {
        let folders = childFolders.map {
            SessionMergedEntryWithRank(
                rank: recentActivityIndex(for: $0.id),
                entry: .folder($0)
            )
        }
        let sessions = pagedDirectSessions.map {
            SessionMergedEntryWithRank(
                rank: sessionOrderByID[$0.id] ?? .max,
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

    private var moveFolderOptions: [SessionMoveFolderOption] {
        viewModel.sessionFolders
            .sorted { lhs, rhs in
                let left = folderDisplayPath(lhs)
                let right = folderDisplayPath(rhs)
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            .map { folder in
                SessionMoveFolderOption(id: folder.id, title: folderDisplayPath(folder))
            }
    }

    private var selectedSessions: [ChatSession] {
        pagedDirectSessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var normalizedSearchQuery: String {
        SessionHistorySearchSupport.normalizedQuery(searchText)
    }

    private var isSearchActive: Bool {
        isRoot && !normalizedSearchQuery.isEmpty
    }

    private var searchResultSessions: [ChatSession] {
        guard isSearchActive else { return [] }
        return viewModel.chatSessions.filter { searchHits[$0.id] != nil }
    }

    private var searchResultItems: [SessionHistorySearchResult] {
        guard isSearchActive else { return [] }
        return SessionHistorySearchSupport.flattenedResults(
            sessions: viewModel.chatSessions,
            hits: searchHits
        )
    }

    private var totalSearchResultCount: Int {
        searchResultItems.count
    }

    private var totalSearchResultPages: Int {
        guard totalSearchResultCount > 0 else { return 1 }
        return ((totalSearchResultCount - 1) / maxSessionsPerPage) + 1
    }

    private var shouldShowSearchPaginationBar: Bool {
        totalSearchResultCount > maxSessionsPerPage
    }

    private var pagedSearchResultItems: [SessionHistorySearchResult] {
        guard totalSearchResultCount > 0 else { return [] }
        let start = min(searchResultPageIndex * maxSessionsPerPage, totalSearchResultCount)
        let end = min(start + maxSessionsPerPage, totalSearchResultCount)
        guard start < end else { return [] }
        return Array(searchResultItems[start..<end])
    }

    private var emptyStateText: String {
        folderID == nil ? "暂无文件夹或会话。" : "当前文件夹暂无内容。"
    }

    private var canGoToPreviousPage: Bool {
        sessionPageIndex > 0
    }

    private var canGoToNextPage: Bool {
        sessionPageIndex + 1 < totalSessionPages
    }

    private var canGoToPreviousSearchResultPage: Bool {
        searchResultPageIndex > 0
    }

    private var canGoToNextSearchResultPage: Bool {
        searchResultPageIndex + 1 < totalSearchResultPages
    }

    private var currentPageStartOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return sessionPageIndex * maxSessionsPerPage + 1
    }

    private var currentPageEndOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return min((sessionPageIndex + 1) * maxSessionsPerPage, totalDirectSessionCount)
    }

    private var currentSearchResultPageStartOrdinal: Int {
        guard totalSearchResultCount > 0 else { return 0 }
        return searchResultPageIndex * maxSessionsPerPage + 1
    }

    private var currentSearchResultPageEndOrdinal: Int {
        guard totalSearchResultCount > 0 else { return 0 }
        return min((searchResultPageIndex + 1) * maxSessionsPerPage, totalSearchResultCount)
    }

    private var paginationSummaryText: String {
        "当前显示\(currentPageStartOrdinal)-\(currentPageEndOrdinal)个对话(总共\(totalDirectSessionCount))"
    }

    private var searchPaginationSummaryText: String {
        "当前显示\(currentSearchResultPageStartOrdinal)-\(currentSearchResultPageEndOrdinal)条结果(总共\(totalSearchResultCount))"
    }

    private var shouldShowActivePaginationBar: Bool {
        isSearchActive ? shouldShowSearchPaginationBar : shouldShowPaginationBar
    }

    private var activePaginationSummaryText: String {
        isSearchActive ? searchPaginationSummaryText : paginationSummaryText
    }

    private var canGoToPreviousActivePage: Bool {
        isSearchActive ? canGoToPreviousSearchResultPage : canGoToPreviousPage
    }

    private var canGoToNextActivePage: Bool {
        isSearchActive ? canGoToNextSearchResultPage : canGoToNextPage
    }

    var body: some View {
        applySheetAndGhostAlert(
            to: applyDeleteFolderAlert(
                to: applyFolderEditingAlerts(
                    to: applySessionAlerts(
                        to: applyStateHandlers(to: listScaffold)
                    )
                )
            )
        )
    }

    private var listScaffold: some View {
        let entries = mergedEntries
        let baseList = List {
            if isSearchActive {
                searchResultSection
            } else {
                if entries.isEmpty {
                    Text(emptyStateText)
                        .foregroundStyle(.secondary)
                }

                ForEach(entries) { entry in
                    mergedEntryRow(entry)
                }
            }
        }
        .navigationTitle(isRoot ? "会话管理" : (currentFolder?.name ?? "文件夹"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sessionListActionsMenu
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isBatchSelecting && !isSearchActive {
                batchActionBar
            } else if shouldShowActivePaginationBar {
                paginationBar
            }
        }
        return applySearchModifier(to: baseList)
    }

    private var pagedSessionIDs: [UUID] {
        pagedDirectSessions.map(\.id)
    }

    private func applyStateHandlers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: viewModel.sessionFolders) { _, _ in
                guard folderID != nil else { return }
                if currentFolder == nil {
                    dismiss()
                }
            }
            .onChange(of: pagedSessionIDs) { _, visibleIDs in
                selectedSessionIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: totalDirectSessionCount) { _, _ in
                normalizeSessionPageIndex()
            }
            .onChange(of: totalSearchResultCount) { _, _ in
                normalizeSearchResultPageIndex()
            }
            .onAppear {
                normalizeSessionPageIndex()
                normalizeSearchResultPageIndex()
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: searchText) { _, newValue in
                guard isRoot else { return }
                if !SessionHistorySearchSupport.normalizedQuery(newValue).isEmpty, isBatchSelecting {
                    isBatchSelecting = false
                    selectedSessionIDs.removeAll()
                }
                searchResultPageIndex = 0
                scheduleSearch(for: newValue)
            }
            .onChange(of: viewModel.chatSessions) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: viewModel.currentSession?.id) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: viewModel.allMessagesForSession) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onDisappear {
                guard isRoot else { return }
                pendingSearchWorkItem?.cancel()
                pendingSearchWorkItem = nil
            }
    }

    private func applySessionAlerts<Content: View>(to content: Content) -> some View {
        content
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
            .alert("确认批量删除", isPresented: $showBatchDeleteConfirm) {
                Button("删除", role: .destructive) {
                    performBatchDelete()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除 \(selectedSessionIDs.count) 个会话，操作不可恢复。")
            }
    }

    private func applyFolderEditingAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert("新建文件夹", isPresented: $isShowingCreateFolderAlert) {
                TextField("文件夹名称", text: $createFolderName)
                Button("创建") {
                    let trimmed = createFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = viewModel.createSessionFolder(name: trimmed, parentID: createFolderParentID)
                    createFolderName = ""
                    createFolderParentID = nil
                }
                Button("取消", role: .cancel) {
                    createFolderName = ""
                    createFolderParentID = nil
                }
            } message: {
                if let createFolderParentID,
                   let parentFolder = folderByID[createFolderParentID] {
                    Text("将在“\(parentFolder.name)”下创建子文件夹。")
                } else {
                    Text("请输入新的文件夹名称。")
                }
            }
            .alert("重命名文件夹", isPresented: $isShowingRenameFolderAlert) {
                TextField("文件夹名称", text: $renameFolderName)
                Button("保存") {
                    guard let folderToRename else { return }
                    let trimmed = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    viewModel.renameSessionFolder(folderToRename, newName: trimmed)
                    self.folderToRename = nil
                    renameFolderName = ""
                }
                Button("取消", role: .cancel) {
                    folderToRename = nil
                    renameFolderName = ""
                }
            } message: {
                Text("请输入新的文件夹名称。")
            }
    }

    private func applyDeleteFolderAlert<Content: View>(to content: Content) -> some View {
        content
            .alert("确认删除文件夹", isPresented: Binding(
                get: { folderToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        folderToDelete = nil
                    }
                }
            )) {
                Button("删除", role: .destructive) {
                    if let folderToDelete {
                        viewModel.deleteSessionFolder(folderToDelete)
                    }
                    folderToDelete = nil
                }
                Button("取消", role: .cancel) {
                    folderToDelete = nil
                }
            } message: {
                if let folderToDelete {
                    let descendantIDs = descendantFolderIDs(rootID: folderToDelete.id)
                    let folderCount = descendantIDs.count
                    let affectedSessions = viewModel.chatSessions.filter { session in
                        guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
                        return descendantIDs.contains(assignedFolderID)
                    }.count
                    Text("将删除 \(folderCount) 个文件夹。\(affectedSessions) 个会话将移回未分类。")
                }
            }
    }

    private func applySheetAndGhostAlert<Content: View>(to content: Content) -> some View {
        content
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

    private func applySearchModifier<Content: View>(to content: Content) -> some View {
        if isRoot {
            return AnyView(
                content
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("搜索会话标题或消息")
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            )
        }
        return AnyView(content)
    }

    @ViewBuilder
    private var searchResultSection: some View {
        Section {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在搜索历史会话…")
                        .foregroundStyle(.secondary)
                }
            } else if searchResultSessions.isEmpty {
                Text("未找到匹配的搜索结果。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pagedSearchResultItems) { result in
                    searchResultRow(result)
                }
            }
        } header: {
            Text("搜索结果")
        } footer: {
            if !isSearching {
                Text("匹配 \(searchResultItems.count) 条结果 / \(searchResultSessions.count) 个会话")
            }
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    applyBatchMove(toFolderID: nil)
                } label: {
                    Label("未分类", systemImage: "tray")
                }

                ForEach(moveFolderOptions) { option in
                    Button {
                        applyBatchMove(toFolderID: option.id)
                    } label: {
                        Label(option.title, systemImage: "folder")
                    }
                }
            } label: {
                Label("移动", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedSessionIDs.isEmpty)

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedSessionIDs.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var paginationBar: some View {
        HStack(spacing: 10) {
            paginationButton(
                systemName: "chevron.left",
                accessibilityLabel: "上一页",
                isEnabled: canGoToPreviousActivePage,
                action: goToPreviousActivePage
            )

            paginationSummaryField

            paginationButton(
                systemName: "chevron.right",
                accessibilityLabel: "下一页",
                isEnabled: canGoToNextActivePage,
                action: goToNextActivePage
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var paginationSummaryField: some View {
        let field = Text(activePaginationSummaryText)
            .etFont(.callout)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)

        if #available(iOS 26.0, *) {
            field
                .glassEffect(.clear, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        } else {
            field
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule()
                        .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
                )
        }
    }

    private func paginationButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .etFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .background(paginationButtonBackground)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var paginationButtonBackground: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(Color.clear)
                .glassEffect(.clear, in: Circle())
                .overlay(
                    Circle()
                        .fill(Color(uiColor: .systemBackground).opacity(0.22))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
                )
        }
    }

    private func mergedEntryRow(_ entry: SessionMergedEntry) -> AnyView {
        switch entry {
        case .folder(let folder):
            return AnyView(folderRow(folder))
        case .session(let session):
            return AnyView(sessionRow(session))
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: SessionFolder) -> some View {
        if isBatchSelecting {
            folderLabel(for: folder)
        } else {
            NavigationLink {
                SessionFolderBrowserView(
                    folderID: folder.id,
                    isRoot: false,
                    createConversationAction: createConversationAction
                )
            } label: {
                folderLabel(for: folder)
            }
            .contextMenu {
                Button {
                    startRenaming(folder)
                } label: {
                    Label("重命名文件夹", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    folderToDelete = folder
                } label: {
                    Label("删除文件夹", systemImage: "trash")
                }
            }
        }
    }

    private var sessionListActionsMenu: some View {
        Menu {
            if let createConversationAction {
                Button {
                    createConversationAction()
                } label: {
                    Label("新建对话", systemImage: "plus.message")
                }
            }

            Button {
                presentCreateFolder(parentID: folderID)
            } label: {
                Label(folderID == nil ? "新建文件夹" : "新建子文件夹", systemImage: "folder.badge.plus")
            }

            Button {
                toggleBatchMode()
            } label: {
                Label(
                    isBatchSelecting ? "结束批量选择" : "批量选择",
                    systemImage: isBatchSelecting ? "checkmark.circle.fill" : "pencil"
                )
            }
            .disabled(isSearchActive)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func sessionRow(
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
    private func searchResultRow(_ result: SessionHistorySearchResult) -> some View {
        if let session = viewModel.chatSessions.first(where: { $0.id == result.sessionID }) {
            Button {
                selectSession(session, messageOrdinal: result.messageOrdinal)
            } label: {
                MarqueeTitleSubtitleSelectionRow(
                    title: searchResultTitle(for: result),
                    subtitle: result.match.preview,
                    isSelected: session.id == viewModel.currentSession?.id
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func folderLabel(for folder: SessionFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .etFont(.headline)
                let count = recursiveSessionCount(in: folder.id)
                Text("\(count) 个会话")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleBatchMode() {
        isBatchSelecting.toggle()
        if !isBatchSelecting {
            selectedSessionIDs.removeAll()
        }
    }

    private func toggleSessionSelection(_ sessionID: UUID) {
        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    private func applyBatchMove(toFolderID folderID: UUID?) {
        for session in selectedSessions {
            viewModel.moveSession(session, toFolderID: folderID)
        }
        selectedSessionIDs.removeAll()
    }

    private func performBatchDelete() {
        let sessions = selectedSessions
        guard !sessions.isEmpty else { return }
        viewModel.deleteSessions(sessions)
        selectedSessionIDs.removeAll()
    }

    private func normalizeSessionPageIndex() {
        let maxIndex = max(totalSessionPages - 1, 0)
        if sessionPageIndex > maxIndex {
            sessionPageIndex = maxIndex
        }
        if sessionPageIndex < 0 {
            sessionPageIndex = 0
        }
    }

    private func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        sessionPageIndex -= 1
    }

    private func goToNextPage() {
        guard canGoToNextPage else { return }
        sessionPageIndex += 1
    }

    private func normalizeSearchResultPageIndex() {
        let maxIndex = max(totalSearchResultPages - 1, 0)
        if searchResultPageIndex > maxIndex {
            searchResultPageIndex = maxIndex
        }
        if searchResultPageIndex < 0 {
            searchResultPageIndex = 0
        }
    }

    private func goToPreviousActivePage() {
        if isSearchActive {
            guard canGoToPreviousSearchResultPage else { return }
            searchResultPageIndex -= 1
            return
        }
        goToPreviousPage()
    }

    private func goToNextActivePage() {
        if isSearchActive {
            guard canGoToNextSearchResultPage else { return }
            searchResultPageIndex += 1
            return
        }
        goToNextPage()
    }

    private func normalizedFolderID(of session: ChatSession) -> UUID? {
        guard let folderID = session.folderID else { return nil }
        return folderByID[folderID] == nil ? nil : folderID
    }

    private func normalizedParentID(of folder: SessionFolder) -> UUID? {
        guard let parentID = folder.parentID else { return nil }
        return folderByID[parentID] == nil ? nil : parentID
    }

    private func recentActivityIndex(for folderID: UUID) -> Int {
        let sessions = viewModel.chatSessions
        for (index, session) in sessions.enumerated() {
            guard let assignedFolderID = normalizedFolderID(of: session) else { continue }
            if folderHierarchyContains(descendantFolderID: assignedFolderID, ancestorFolderID: folderID) {
                return index
            }
        }
        return .max
    }

    private func folderHierarchyContains(descendantFolderID: UUID, ancestorFolderID: UUID) -> Bool {
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

    private func descendantFolderIDs(rootID: UUID) -> Set<UUID> {
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

    private func recursiveSessionCount(in folderID: UUID) -> Int {
        let descendants = descendantFolderIDs(rootID: folderID)
        return viewModel.chatSessions.filter { session in
            guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID)
        }.count
    }

    private func folderDisplayPath(_ folder: SessionFolder) -> String {
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

    private func folderLocationSummary(for session: ChatSession) -> String {
        guard let folderID = normalizedFolderID(of: session),
              let folder = folderByID[folderID] else {
            return "位置：未分类"
        }
        return "位置：\(folderDisplayPath(folder))"
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

    private func searchResultTitle(for result: SessionHistorySearchResult) -> String {
        if let messageOrdinal = result.messageOrdinal {
            return "“\(result.sessionName)” 第\(messageOrdinal)条"
        }
        return "“\(result.sessionName)” \(sourceLabel(for: result.match.source))"
    }

    private func scheduleSearch(for query: String) {
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

    private func presentCreateFolder(parentID: UUID?) {
        createFolderParentID = parentID
        createFolderName = ""
        isShowingCreateFolderAlert = true
    }

    private func startRenaming(_ folder: SessionFolder) {
        folderToRename = folder
        renameFolderName = folder.name
        isShowingRenameFolderAlert = true
    }

    /// 选择会话时检测是否为 Ghost Session
    private func selectSession(_ session: ChatSession, messageOrdinal: Int? = nil) {
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

    private func focusOnLatest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editingSessionID = viewModel.currentSession?.id
            draftSessionName = viewModel.currentSession?.name ?? ""
        }
    }
}

private struct SessionMergedEntryWithRank {
    let rank: Int
    let entry: SessionMergedEntry
}

private enum SessionMergedEntry: Identifiable {
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

private struct SessionMoveFolderOption: Identifiable {
    let id: UUID
    let title: String
}

private struct BatchSelectableSessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .etFont(.headline)
                        .foregroundStyle(.primary)
                    if let topic = session.topicPrompt, !topic.isEmpty {
                        Text(topic)
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let currentFolderID: UUID?
    let moveOptions: [SessionMoveFolderOption]
    let searchSummary: String?
    let locationSummary: String?

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onMoveToFolder: (UUID?) -> Void
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
                            .etFont(.headline)
                        if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let locationSummary, !locationSummary.isEmpty {
                            Text(locationSummary)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let searchSummary, !searchSummary.isEmpty {
                            Text(searchSummary)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }

                    Spacer()

                    if isRunning {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .etFont(.footnote.bold())
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

            Menu {
                Button {
                    onMoveToFolder(nil)
                } label: {
                    Label("未分类", systemImage: currentFolderID == nil ? "checkmark" : "tray")
                }

                ForEach(moveOptions) { option in
                    Button {
                        onMoveToFolder(option.id)
                    } label: {
                        Label(option.title, systemImage: currentFolderID == option.id ? "checkmark" : "folder")
                    }
                }
            } label: {
                Label("移动到文件夹", systemImage: "folder")
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

private struct SessionInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

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
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let enhanced = payload.session.enhancedPrompt, !enhanced.isEmpty {
                    Section("增强提示词") {
                        Text(enhanced)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("唯一标识") {
                    Text(payload.session.id.uuidString)
                        .etFont(.footnote.monospaced())
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
