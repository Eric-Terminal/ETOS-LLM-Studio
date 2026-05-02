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
extension SessionFolderBrowserView {

    var folderByID: [UUID: SessionFolder] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    }

    var currentFolder: SessionFolder? {
        guard let folderID else { return nil }
        return folderByID[folderID]
    }

    var childFolders: [SessionFolder] {
        folders.filter { normalizedParentID(of: $0) == folderID }
    }

    var directSessions: [ChatSession] {
        sessions.filter { normalizedFolderID(of: $0) == folderID }
    }

    var totalDirectSessionCount: Int {
        directSessions.count
    }

    var totalSessionPages: Int {
        guard totalDirectSessionCount > 0 else { return 1 }
        return ((totalDirectSessionCount - 1) / maxSessionsPerPage) + 1
    }

    var shouldShowPaginationBar: Bool {
        totalDirectSessionCount > maxSessionsPerPage
    }

    var pagedDirectSessions: [ChatSession] {
        guard totalDirectSessionCount > 0 else { return [] }
        let start = min(sessionPageIndex * maxSessionsPerPage, totalDirectSessionCount)
        let end = min(start + maxSessionsPerPage, totalDirectSessionCount)
        guard start < end else { return [] }
        return Array(directSessions[start..<end])
    }

    var sessionOrderByID: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
    }

    var mergedEntries: [SessionMergedEntry] {
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

    var moveTargets: [SessionMoveTarget] {
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

    var batchMoveTargets: [SessionMoveTarget] {
        moveTargets.filter { isValidBatchMoveTarget($0.id) }
    }

    var selectedSessions: [ChatSession] {
        pagedDirectSessions.filter { selectedSessionIDs.contains($0.id) }
    }

    var selectedFolders: [SessionFolder] {
        childFolders.filter { selectedFolderIDs.contains($0.id) }
    }

    var selectedBatchItemCount: Int {
        selectedSessionIDs.count + selectedFolderIDs.count
    }

    var hasBatchSelection: Bool {
        selectedBatchItemCount > 0
    }

    var emptyStateText: String {
        folderID == nil ? NSLocalizedString("暂无文件夹或会话。", comment: "") : NSLocalizedString("当前文件夹暂无内容。", comment: "")
    }

    var canGoToPreviousPage: Bool {
        sessionPageIndex > 0
    }

    var canGoToNextPage: Bool {
        sessionPageIndex + 1 < totalSessionPages
    }

    var currentPageStartOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return sessionPageIndex * maxSessionsPerPage + 1
    }

    var currentPageEndOrdinal: Int {
        guard totalDirectSessionCount > 0 else { return 0 }
        return min((sessionPageIndex + 1) * maxSessionsPerPage, totalDirectSessionCount)
    }

    var paginationSummaryText: String {
        String(format: NSLocalizedString("当前显示%d-%d个对话(总共%d)", comment: ""), currentPageStartOrdinal, currentPageEndOrdinal, totalDirectSessionCount)
    }

    var paginationCapsuleStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }

    var body: some View {
        applyDialogs(to: applySheets(to: applyStateHandlers(to: listScaffold)))
    }

    var listScaffold: some View {
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
        .navigationTitle(isRoot ? NSLocalizedString("历史会话", comment: "") : (currentFolder?.name ?? NSLocalizedString("文件夹", comment: "")))
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

    var pagedSessionIDs: [UUID] {
        pagedDirectSessions.map(\.id)
    }

    var childFolderIDs: [UUID] {
        childFolders.map(\.id)
    }

    func applyStateHandlers<Content: View>(to content: Content) -> some View {
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

    func applySheets<Content: View>(to content: Content) -> some View {
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
                    .navigationTitle(folderBeingRenamed == nil ? NSLocalizedString("新建文件夹", comment: "") : NSLocalizedString("重命名文件夹", comment: ""))
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

    func applyDialogs<Content: View>(to content: Content) -> some View {
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
                    Text(String(format: NSLocalizedString("将删除 %d 个文件夹。%d 个会话将回到未分类。", comment: ""), folderCount, sessionCount))
                }
            }
    }

    var moreActionsSheet: some View {
        NavigationStack {
            List {
                if isBatchSelecting {
                    Section {
                        Text(String(format: NSLocalizedString("已选 %d 个项目", comment: ""), selectedBatchItemCount))
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
                            Label(folderID == nil ? NSLocalizedString("新建文件夹", comment: "") : NSLocalizedString("新建子文件夹", comment: ""), systemImage: "folder.badge.plus")
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

    var paginationBottomBar: some View {
        WatchPaginationBar(
            summaryText: paginationSummaryText,
            canGoToPrevious: canGoToPreviousPage,
            canGoToNext: canGoToNextPage,
            onPrevious: goToPreviousPage,
            onNext: goToNextPage,
            strokeColor: paginationCapsuleStrokeColor
        )
    }

    func mergedEntryRow(_ entry: SessionMergedEntry) -> AnyView {
        switch entry {
        case .folder(let folder):
            return AnyView(folderRow(folder))
        case .session(let session):
            return AnyView(sessionRow(session))
        }
    }

    @ViewBuilder
    func folderRow(_ folder: SessionFolder) -> some View {
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
    func sessionRow(_ session: ChatSession) -> some View {
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
    func folderLabel(for folder: SessionFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .etFont(.footnote)
                    .lineLimit(1)
                Text(String(format: NSLocalizedString("%d 个会话", comment: ""), recursiveSessionCount(in: folder.id)))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func toggleBatchMode() {
        isBatchSelecting.toggle()
        if !isBatchSelecting {
            selectedSessionIDs.removeAll()
            selectedFolderIDs.removeAll()
        }
    }

    func endBatchMode() {
        isBatchSelecting = false
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    func dismissMoreActionsThen(_ action: @escaping () -> Void) {
        showMoreActions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            action()
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
            moveSessionToFolderAction(session, folderID)
        }
        for folder in selectedFolders {
            moveFolderToFolderAction(folder, folderID)
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
        let targetSessions = selectedSessions
        let targetFolders = selectedFolders
        guard !targetSessions.isEmpty || !targetFolders.isEmpty else { return }
        targetSessions.forEach { deleteSessionAction($0) }
        targetFolders.forEach { deleteFolderAction($0) }
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

    func openCreateFolderEditor(parentID: UUID?) {
        folderBeingRenamed = nil
        folderEditorParentID = parentID
        folderEditorName = ""
        isShowingFolderEditor = true
    }

    func openRenameFolderEditor(_ folder: SessionFolder) {
        folderBeingRenamed = folder
        folderEditorParentID = nil
        folderEditorName = folder.name
        isShowingFolderEditor = true
    }

    func resetFolderEditorState() {
        folderBeingRenamed = nil
        folderEditorParentID = nil
        folderEditorName = ""
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
        for (index, session) in sessions.enumerated() {
            guard let assignedFolderID = normalizedFolderID(of: session) else { continue }
            if folderHierarchyContains(descendantFolderID: assignedFolderID, ancestorFolderID: folderID) {
                return index
            }
        }
        return .max
    }
}
