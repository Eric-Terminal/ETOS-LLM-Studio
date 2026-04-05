// ============================================================================
// SessionListView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话历史列表视图
//
// 功能特性:
// - 以“文件管理”方式浏览会话文件夹
// - 支持会话移动、删除、分支与重命名
// - 支持文件夹新建、重命名、删除
// ============================================================================

import SwiftUI
import Foundation
import Shared

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

    private var folderByID: [UUID: SessionFolder] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    }

    private var currentFolder: SessionFolder? {
        guard let folderID else { return nil }
        return folderByID[folderID]
    }

    private var childFolders: [SessionFolder] {
        let candidates = folders.filter { normalizedParentID(of: $0) == folderID }
        return candidates.sorted { lhs, rhs in
            let leftRecency = recentActivityIndex(for: lhs.id)
            let rightRecency = recentActivityIndex(for: rhs.id)
            if leftRecency != rightRecency {
                return leftRecency < rightRecency
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var directSessions: [ChatSession] {
        sessions.filter { normalizedFolderID(of: $0) == folderID }
    }

    var body: some View {
        List {
            if isRoot {
                Section {
                    Button {
                        openCreateFolderEditor(parentID: nil)
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                }
            }

            Section("文件夹") {
                if childFolders.isEmpty {
                    Text("暂无文件夹。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(childFolders) { folder in
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
                    .contextMenu {
                        Button {
                            openRenameFolderEditor(folder)
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

            Section(folderID == nil ? "未分类会话" : "会话") {
                if directSessions.isEmpty {
                    Text(folderID == nil ? "未分类会话为空。" : "当前文件夹暂无会话。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(directSessions) { session in
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
        }
        .navigationTitle(isRoot ? "历史会话" : (currentFolder?.name ?? "文件夹"))
        .toolbar {
            if let currentFolder {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            openCreateFolderEditor(parentID: currentFolder.id)
                        } label: {
                            Label("新建子文件夹", systemImage: "folder.badge.plus")
                        }

                        Button {
                            openRenameFolderEditor(currentFolder)
                        } label: {
                            Label("重命名当前文件夹", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            folderToDelete = currentFolder
                        } label: {
                            Label("删除当前文件夹", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .onChange(of: folders) { _, _ in
            guard folderID != nil else { return }
            if currentFolder == nil {
                dismiss()
            }
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
