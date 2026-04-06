// ============================================================================
// SessionListView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话历史列表视图
//
// 功能特性:
// - 文件夹与会话在同一列表混合展示
// - 顶部三点菜单支持新建文件夹与批量选中
// - 支持会话批量移动、批量删除
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

    // MARK: - 操作

    let deleteSessionAction: (ChatSession) -> Void
    let branchAction: (ChatSession, Bool) -> ChatSession?
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let onSessionSelected: (ChatSession) -> Void
    let updateSessionAction: (ChatSession) -> Void
    let createFolderAction: (String, UUID?) -> SessionFolder?
    let renameFolderAction: (SessionFolder, String) -> Void
    let deleteFolderAction: (SessionFolder) -> Void
    let moveSessionToFolderAction: (ChatSession, UUID?) -> Void

    var body: some View {
        SessionFolderBrowserView(
            folderID: nil,
            sessions: $sessions,
            folders: $folders,
            currentSession: $currentSession,
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
            isRoot: true
        )
    }
}

private struct SessionFolderBrowserView: View {
    let folderID: UUID?

    @Binding var sessions: [ChatSession]
    @Binding var folders: [SessionFolder]
    @Binding var currentSession: ChatSession?

    let deleteSessionAction: (ChatSession) -> Void
    let branchAction: (ChatSession, Bool) -> ChatSession?
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let onSessionSelected: (ChatSession) -> Void
    let updateSessionAction: (ChatSession) -> Void
    let createFolderAction: (String, UUID?) -> SessionFolder?
    let renameFolderAction: (SessionFolder, String) -> Void
    let deleteFolderAction: (SessionFolder) -> Void
    let moveSessionToFolderAction: (ChatSession, UUID?) -> Void
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
    @State private var showBatchDeleteConfirm = false
    @State private var showBatchMovePicker = false

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

        let sessionEntries = directSessions.map {
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

    private var selectedSessions: [ChatSession] {
        directSessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var emptyStateText: String {
        folderID == nil ? "暂无文件夹或会话。" : "当前文件夹暂无内容。"
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
        }
        .safeAreaInset(edge: .bottom) {
            if isBatchSelecting {
                batchActionBar
            }
        }
    }

    private var directSessionIDs: [UUID] {
        directSessions.map(\.id)
    }

    private func applyStateHandlers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: folders) { _, _ in
                guard folderID != nil else { return }
                if currentFolder == nil {
                    dismiss()
                }
            }
            .onChange(of: directSessionIDs) { _, visibleIDs in
                selectedSessionIDs.formIntersection(Set(visibleIDs))
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
                        TextField("文件夹名称", text: $folderEditorName)
                    }
                    .navigationTitle(folderBeingRenamed == nil ? "新建文件夹" : "重命名文件夹")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") {
                                resetFolderEditorState()
                                isShowingFolderEditor = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
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
            .sheet(isPresented: $showBatchMovePicker) {
                NavigationStack {
                    BatchMoveDestinationPickerView(moveTargets: moveTargets) { targetFolderID in
                        applyBatchMove(toFolderID: targetFolderID)
                    }
                }
            }
    }

    private func applyDialogs<Content: View>(to content: Content) -> some View {
        content
            .confirmationDialog("确认删除会话", isPresented: $showDeleteSessionConfirm, titleVisibility: .visible) {
                Button("删除会话", role: .destructive) {
                    if let sessionToDelete {
                        deleteSessionAction(sessionToDelete)
                    }
                    self.sessionToDelete = nil
                }
                Button("取消", role: .cancel) {
                    sessionToDelete = nil
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
            .confirmationDialog("会话列表操作", isPresented: $showMoreActions, titleVisibility: .visible) {
                Button(folderID == nil ? "新建文件夹" : "新建子文件夹") {
                    openCreateFolderEditor(parentID: folderID)
                }

                Button(isBatchSelecting ? "结束批量选中" : "批量选中") {
                    toggleBatchMode()
                }

                if let currentFolder {
                    Button("重命名当前文件夹") {
                        openRenameFolderEditor(currentFolder)
                    }

                    Button("删除当前文件夹", role: .destructive) {
                        folderToDelete = currentFolder
                    }
                }

                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("确认批量删除", isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
                Button("删除所选会话", role: .destructive) {
                    performBatchDelete()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除 \(selectedSessionIDs.count) 个会话，操作不可恢复。")
            }
            .confirmationDialog("确认删除文件夹", isPresented: Binding(
                get: { folderToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        folderToDelete = nil
                    }
                }
            ), titleVisibility: .visible) {
                Button("删除文件夹", role: .destructive) {
                    if let folderToDelete {
                        deleteFolderAction(folderToDelete)
                    }
                    folderToDelete = nil
                }
                Button("取消", role: .cancel) {
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

    private var batchActionBar: some View {
        VStack(spacing: 8) {
            Text("已选 \(selectedSessionIDs.count) 个会话")
                .etFont(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    showBatchMovePicker = true
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
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
                    sessions: $sessions,
                    folders: $folders,
                    currentSession: $currentSession,
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
            moveSessionToFolderAction(session, folderID)
        }
        selectedSessionIDs.removeAll()
    }

    private func performBatchDelete() {
        let targets = selectedSessions
        guard !targets.isEmpty else { return }
        targets.forEach { deleteSessionAction($0) }
        selectedSessionIDs.removeAll()
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
                Label("未分类", systemImage: "tray")
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
        .navigationTitle("移动到文件夹")
    }
}

// MARK: - 私有子视图

private struct SessionRowView: View {

    let session: ChatSession
    @Binding var currentSession: ChatSession?
    @Binding var folders: [SessionFolder]
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionToDelete: ChatSession?
    @Binding var showDeleteSessionConfirm: Bool

    let onSessionSelected: (ChatSession) -> Void
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let moveSessionToFolderAction: (ChatSession, UUID?) -> Void

    var body: some View {
        Button(action: { onSessionSelected(session) }) {
            HStack {
                MarqueeText(content: session.name, uiFont: .preferredFont(forTextStyle: .headline))
                    .foregroundColor(.primary)
                    .allowsHitTesting(false)

                if currentSession?.id == session.id {
                    Spacer()
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
                Label("更多", systemImage: "ellipsis")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                sessionToDelete = session
                showDeleteSessionConfirm = true
            } label: {
                Label("删除会话", systemImage: "trash")
            }
        }
    }
}
