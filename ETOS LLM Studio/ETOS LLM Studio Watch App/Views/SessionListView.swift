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

private struct SessionFolderBrowserView: View {
    let folderID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    @Binding var sessions: [ChatSession]
    @Binding var folders: [SessionFolder]
    @Binding var currentSession: ChatSession?
    let runningSessionIDs: Set<UUID>

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
    let createConversationAction: (() -> Void)?
    let isRoot: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteSessionConfirm: Bool = false
    @State private var sessionToDelete: ChatSession?
    @State private var sessionToEdit: ChatSession?
    @State private var showBranchOptions: Bool = false
    @State private var sessionToBranch: ChatSession?

    @State private var isShowingFolderEditor = false
    @State private var folderEditorName: String = ""
    @State private var folderEditorParentID: UUID?
    @State private var folderBeingRenamed: SessionFolder?
    @State private var folderToDelete: SessionFolder?
    @State private var showMoreActions = false

    @State private var isBatchSelecting = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showSessionSearch = false
    @State private var sessionPageIndex: Int = 0

    private let maxSessionsPerPage = 50

    private var folderByID: [UUID: SessionFolder] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    }

    private var currentFolder: SessionFolder? {
        guard let folderID else { return nil }
        return folderByID[folderID]
    }

    private var childFolders: [SessionFolder] {
        folders.filter { normalizedParentID(of: $0) == folderID }
    }

    private var directSessions: [ChatSession] {
        sessions.filter { normalizedFolderID(of: $0) == folderID }
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
        Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
    }

    private var mergedEntries: [SessionMergedEntry] {
        let folderEntries = childFolders.map {
            SessionMergedEntryWithRank(
                rank: recentActivityIndex(for: $0.id),
                entry: .folder($0)
            )
        }

        let sessionEntries = pagedDirectSessions.map {
            SessionMergedEntryWithRank(
                rank: sessionOrderByID[$0.id] ?? .max,
                entry: .session($0)
            )
        }

        return (folderEntries + sessionEntries)
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

    private var moveTargets: [SessionMoveTarget] {
        folders
            .sorted { lhs, rhs in
                let left = folderPath(lhs)
                let right = folderPath(rhs)
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            .map { folder in
                SessionMoveTarget(id: folder.id, title: folderPath(folder))
            }
    }

    private var batchMoveTargets: [SessionMoveTarget] {
        moveTargets.filter { isValidBatchMoveTarget($0.id) }
    }

    private var selectedSessions: [ChatSession] {
        pagedDirectSessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var selectedFolders: [SessionFolder] {
        childFolders.filter { selectedFolderIDs.contains($0.id) }
    }

    private var selectedBatchItemCount: Int {
        selectedSessionIDs.count + selectedFolderIDs.count
    }

    private var hasBatchSelection: Bool {
        selectedBatchItemCount > 0
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

    private var currentPageStartOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return sessionPageIndex * maxSessionsPerPage + 1
    }

    private var currentPageEndOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return min((sessionPageIndex + 1) * maxSessionsPerPage, totalDirectSessionCount)
    }

    private var paginationSummaryText: String {
        "当前显示\(currentPageStartOrdinal)-\(currentPageEndOrdinal)个对话(总共\(totalDirectSessionCount))"
    }

    private var paginationCapsuleStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }

    var body: some View {
        applyDialogs(to: applySheets(to: applyStateHandlers(to: listScaffold)))
    }

    private var listScaffold: some View {
        List {
            if mergedEntries.isEmpty {
                Text(emptyStateText)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(mergedEntries) { entry in
                mergedEntryRow(entry)
            }
        }
        .navigationTitle(isRoot ? "历史会话" : (currentFolder?.name ?? "文件夹"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMoreActions = true
                } label: {
                    Image(systemName: "ellipsis")
                }
            }

            if !isBatchSelecting && shouldShowPaginationBar {
                ToolbarItem(placement: .bottomBar) {
                    paginationBottomBar
                }
            }
        }
        .navigationDestination(isPresented: $showSessionSearch) {
            WatchSessionSearchView(
                sessions: sessions,
                folders: folders,
                currentSessionID: currentSession?.id,
                onSelect: { session, messageOrdinal in
                    onSessionSelected(session, messageOrdinal)
                }
            )
        }
    }

    private var pagedSessionIDs: [UUID] {
        pagedDirectSessions.map(\.id)
    }

    private var childFolderIDs: [UUID] {
        childFolders.map(\.id)
    }

    private func applyStateHandlers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: folders) { _, _ in
                guard folderID != nil else { return }
                if currentFolder == nil {
                    dismiss()
                }
            }
            .onChange(of: pagedSessionIDs) { _, visibleIDs in
                selectedSessionIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: childFolderIDs) { _, visibleIDs in
                selectedFolderIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: totalDirectSessionCount) { _, _ in
                normalizeSessionPageIndex()
            }
            .onAppear {
                normalizeSessionPageIndex()
            }
    }

    private func applySheets<Content: View>(to content: Content) -> some View {
        content
            .sheet(item: $sessionToEdit) { sessionToEdit in
                if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionToEdit.id }) {
                    let sessionBinding = $sessions[sessionIndex]
                    EditSessionNameView(session: sessionBinding, onSave: { updatedSession in
                        updateSessionAction(updatedSession)
                    })
                }
            }
            .sheet(isPresented: $isShowingFolderEditor) {
                NavigationStack {
                    Form {
                        TextField(NSLocalizedString("文件夹名称", comment: ""), text: $folderEditorName)
                    }
                    .navigationTitle(folderBeingRenamed == nil ? "新建文件夹" : "重命名文件夹")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(NSLocalizedString("取消", comment: "")) {
                                resetFolderEditorState()
                                isShowingFolderEditor = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("保存", comment: "")) {
                                let trimmed = folderEditorName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                if let folderBeingRenamed {
                                    renameFolderAction(folderBeingRenamed, trimmed)
                                } else {
                                    _ = createFolderAction(trimmed, folderEditorParentID)
                                }
                                resetFolderEditorState()
                                isShowingFolderEditor = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showMoreActions) {
                moreActionsSheet
            }
    }

    private func applyDialogs<Content: View>(to content: Content) -> some View {
        content
            .confirmationDialog(NSLocalizedString("确认删除会话", comment: ""), isPresented: $showDeleteSessionConfirm, titleVisibility: .visible) {
                Button(NSLocalizedString("删除会话", comment: ""), role: .destructive) {
                    if let sessionToDelete {
                        deleteSessionAction(sessionToDelete)
                    }
                    self.sessionToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("您确定要删除这个会话及其所有消息吗？此操作无法撤销。", comment: ""))
            }
            .confirmationDialog(NSLocalizedString("创建分支", comment: ""), isPresented: $showBranchOptions, titleVisibility: .visible) {
                Button(NSLocalizedString("仅分支提示词", comment: "")) {
                    if let session = sessionToBranch {
                        if let newSession = branchAction(session, false) {
                            onSessionSelected(newSession, nil)
                        }
                        sessionToBranch = nil
                    }
                }
                Button(NSLocalizedString("分支提示词和对话记录", comment: "")) {
                    if let session = sessionToBranch {
                        if let newSession = branchAction(session, true) {
                            onSessionSelected(newSession, nil)
                        }
                        sessionToBranch = nil
                    }
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    sessionToBranch = nil
                }
            } message: {
                if let session = sessionToBranch {
                    Text(String(format: NSLocalizedString("从“%@”创建新的分支对话。", comment: ""), session.name))
                }
            }
            .confirmationDialog(NSLocalizedString("确认批量删除", comment: ""), isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
                Button(NSLocalizedString("删除所选项目", comment: ""), role: .destructive) {
                    performBatchDelete()
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            } message: {
                Text(batchDeleteMessage)
            }
            .confirmationDialog(NSLocalizedString("确认删除文件夹", comment: ""), isPresented: Binding(
                get: { folderToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        folderToDelete = nil
                    }
                }
            ), titleVisibility: .visible) {
                Button(NSLocalizedString("删除文件夹", comment: ""), role: .destructive) {
                    if let folderToDelete {
                        deleteFolderAction(folderToDelete)
                    }
                    folderToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    folderToDelete = nil
                }
            } message: {
                if let folderToDelete {
                    let descendants = descendantFolderIDs(rootID: folderToDelete.id)
                    let folderCount = descendants.count
                    let sessionCount = sessions.filter { session in
                        guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
                        return descendants.contains(assignedFolderID)
                    }.count
                    Text("将删除 \(folderCount) 个文件夹。\(sessionCount) 个会话将回到未分类。")
                }
            }
    }

    private var moreActionsSheet: some View {
        NavigationStack {
            List {
                if isBatchSelecting {
                    Section {
                        Text("已选 \(selectedBatchItemCount) 个项目")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)

                        NavigationLink {
                            BatchMoveDestinationPickerView(moveTargets: batchMoveTargets) { targetFolderID in
                                applyBatchMove(toFolderID: targetFolderID)
                                showMoreActions = false
                            }
                        } label: {
                            Label(NSLocalizedString("移动所选项目", comment: ""), systemImage: "folder")
                        }
                        .disabled(!hasBatchSelection)

                        Button(role: .destructive) {
                            dismissMoreActionsThen {
                                showBatchDeleteConfirm = true
                            }
                        } label: {
                            Label(NSLocalizedString("删除所选项目", comment: ""), systemImage: "trash")
                        }
                        .disabled(!hasBatchSelection)

                        Button {
                            dismissMoreActionsThen {
                                endBatchMode()
                            }
                        } label: {
                            Label(NSLocalizedString("退出选中模式", comment: ""), systemImage: "xmark.circle")
                        }
                    }
                } else {
                    Section {
                        if let createConversationAction {
                            Button {
                                dismissMoreActionsThen {
                                    createConversationAction()
                                }
                            } label: {
                                Label(NSLocalizedString("新建对话", comment: ""), systemImage: "plus.message")
                            }
                        }

                        Button {
                            dismissMoreActionsThen {
                                showSessionSearch = true
                            }
                        } label: {
                            Label(NSLocalizedString("搜索会话", comment: ""), systemImage: "magnifyingglass")
                        }

                        Button {
                            dismissMoreActionsThen {
                                openCreateFolderEditor(parentID: folderID)
                            }
                        } label: {
                            Label(folderID == nil ? "新建文件夹" : "新建子文件夹", systemImage: "folder.badge.plus")
                        }

                        Button {
                            dismissMoreActionsThen {
                                toggleBatchMode()
                            }
                        } label: {
                            Label(NSLocalizedString("批量选中", comment: ""), systemImage: "checkmark.circle")
                        }
                    }

                    if let currentFolder {
                        Section {
                            Button {
                                dismissMoreActionsThen {
                                    openRenameFolderEditor(currentFolder)
                                }
                            } label: {
                                Label(NSLocalizedString("重命名当前文件夹", comment: ""), systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                dismissMoreActionsThen {
                                    folderToDelete = currentFolder
                                }
                            } label: {
                                Label(NSLocalizedString("删除当前文件夹", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("会话列表操作", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "")) {
                        showMoreActions = false
                    }
                }
            }
        }
    }

    private var paginationBottomBar: some View {
        WatchPaginationBar(
            summaryText: paginationSummaryText,
            canGoToPrevious: canGoToPreviousPage,
            canGoToNext: canGoToNextPage,
            onPrevious: goToPreviousPage,
            onNext: goToNextPage,
            strokeColor: paginationCapsuleStrokeColor
        )
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
    private func sessionRow(_ session: ChatSession) -> some View {
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
    private func folderLabel(for folder: SessionFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .etFont(.footnote)
                    .lineLimit(1)
                Text("\(recursiveSessionCount(in: folder.id)) 个会话")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleBatchMode() {
        isBatchSelecting.toggle()
        if !isBatchSelecting {
            selectedSessionIDs.removeAll()
            selectedFolderIDs.removeAll()
        }
    }

    private func endBatchMode() {
        isBatchSelecting = false
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    private func dismissMoreActionsThen(_ action: @escaping () -> Void) {
        showMoreActions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            action()
        }
    }

    private func toggleSessionSelection(_ sessionID: UUID) {
        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    private func toggleFolderSelection(_ folderID: UUID) {
        if selectedFolderIDs.contains(folderID) {
            selectedFolderIDs.remove(folderID)
        } else {
            selectedFolderIDs.insert(folderID)
        }
    }

    private func applyBatchMove(toFolderID folderID: UUID?) {
        for session in selectedSessions {
            moveSessionToFolderAction(session, folderID)
        }
        for folder in selectedFolders {
            moveFolderToFolderAction(folder, folderID)
        }
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    private func isValidBatchMoveTarget(_ targetFolderID: UUID) -> Bool {
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

    private func performBatchDelete() {
        let targetSessions = selectedSessions
        let targetFolders = selectedFolders
        guard !targetSessions.isEmpty || !targetFolders.isEmpty else { return }
        targetSessions.forEach { deleteSessionAction($0) }
        targetFolders.forEach { deleteFolderAction($0) }
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    private var batchDeleteMessage: String {
        let folderText = selectedFolderIDs.isEmpty ? "" : "\(selectedFolderIDs.count) 个文件夹"
        let sessionText = selectedSessionIDs.isEmpty ? "" : "\(selectedSessionIDs.count) 个会话"
        let targetText = [folderText, sessionText]
            .filter { !$0.isEmpty }
            .joined(separator: "和")
        let targetSummary = targetText.isEmpty ? "所选项目" : targetText
        return "将删除 \(targetSummary)。文件夹内的会话会移回未分类，操作不可恢复。"
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
        unlockConversationArchaeologistIfNeeded()
    }

    private func unlockConversationArchaeologistIfNeeded() {
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

    private func openCreateFolderEditor(parentID: UUID?) {
        folderBeingRenamed = nil
        folderEditorParentID = parentID
        folderEditorName = ""
        isShowingFolderEditor = true
    }

    private func openRenameFolderEditor(_ folder: SessionFolder) {
        folderBeingRenamed = folder
        folderEditorParentID = nil
        folderEditorName = folder.name
        isShowingFolderEditor = true
    }

    private func resetFolderEditorState() {
        folderBeingRenamed = nil
        folderEditorParentID = nil
        folderEditorName = ""
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
            guard visited.insert(current).inserted else { return false }
            cursor = folderByID[current]?.parentID
        }
        return false
    }

    private func descendantFolderIDs(rootID: UUID) -> Set<UUID> {
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

    private func recursiveSessionCount(in folderID: UUID) -> Int {
        let descendants = descendantFolderIDs(rootID: folderID)
        return sessions.filter { session in
            guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
            return descendants.contains(assignedFolderID)
        }.count
    }

    private func folderPath(_ folder: SessionFolder) -> String {
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

private struct SessionMoveTarget: Identifiable {
    let id: UUID
    let title: String
}

private struct BatchSelectableFolderRow: View {
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
                    Text("\(sessionCount) 个会话")
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

private struct BatchSelectableSessionRow: View {
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

private struct BatchMoveDestinationPickerView: View {
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

private struct WatchPaginationBar: View {
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
    private var summaryCapsule: some View {
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

private struct WatchSessionSearchView: View {
    let sessions: [ChatSession]
    let folders: [SessionFolder]
    let currentSessionID: UUID?
    let onSelect: (ChatSession, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText: String = ""
    @State private var committedSearchText: String = ""
    @State private var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State private var isSearching: Bool = false
    @State private var latestSearchToken: Int = 0
    @State private var pendingSearchWorkItem: DispatchWorkItem?
    @State private var resultPageIndex: Int = 0

    private let maxResultsPerPage = 50

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

    private var totalResultPages: Int {
        guard !searchResults.isEmpty else { return 1 }
        return ((searchResults.count - 1) / maxResultsPerPage) + 1
    }

    private var shouldShowResultPagination: Bool {
        searchResults.count > maxResultsPerPage
    }

    private var canGoToPreviousResultPage: Bool {
        resultPageIndex > 0
    }

    private var canGoToNextResultPage: Bool {
        resultPageIndex + 1 < totalResultPages
    }

    private var currentResultPageStartOrdinal: Int {
        guard !searchResults.isEmpty else { return 0 }
        return resultPageIndex * maxResultsPerPage + 1
    }

    private var currentResultPageEndOrdinal: Int {
        guard !searchResults.isEmpty else { return 0 }
        return min((resultPageIndex + 1) * maxResultsPerPage, searchResults.count)
    }

    private var paginationSummaryText: String {
        "当前显示\(currentResultPageStartOrdinal)-\(currentResultPageEndOrdinal)条结果(总共\(searchResults.count))"
    }

    private var paginationStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }

    private var pagedSearchResults: [SessionHistorySearchResult] {
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
                    Text("匹配 \(searchResults.count) 条结果 / \(searchHits.count) 个会话")
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
    private func resultRow(_ result: SessionHistorySearchResult) -> some View {
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

    private func searchResultTitle(for result: SessionHistorySearchResult) -> String {
        if let messageOrdinal = result.messageOrdinal {
            return "“\(result.sessionName)” 第\(messageOrdinal)条"
        }
        return "“\(result.sessionName)” \(sourceLabel(for: result.match.source))"
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

    private func normalizeResultPageIndex() {
        let maxIndex = max(totalResultPages - 1, 0)
        if resultPageIndex > maxIndex {
            resultPageIndex = maxIndex
        }
        if resultPageIndex < 0 {
            resultPageIndex = 0
        }
    }

    private func goToPreviousResultPage() {
        guard canGoToPreviousResultPage else { return }
        resultPageIndex -= 1
    }

    private func goToNextResultPage() {
        guard canGoToNextResultPage else { return }
        resultPageIndex += 1
    }

    private func submitSearch() {
        let committed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        committedSearchText = committed
        resultPageIndex = 0
        scheduleSearch(for: committed)
    }

    private func clearSearch() {
        searchText = ""
        committedSearchText = ""
        resultPageIndex = 0
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

private struct SessionRowView: View {

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
