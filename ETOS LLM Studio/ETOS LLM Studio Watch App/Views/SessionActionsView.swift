// ============================================================================
// SessionActionsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话操作菜单视图
//
// 功能特性:
// - 提供编辑话题、创建分支、移动文件夹、同步删除等操作
// ============================================================================

import SwiftUI
import ETOSCore

private struct WatchSessionRelationshipDetails: Sendable {
    struct Child: Identifiable, Sendable {
        let id: UUID
        let name: String
    }

    let origin: ConversationOrigin?
    let children: [Child]
    let contacts: [LinkedConversationContact]
}

struct SessionActionsView: View {

    // MARK: - 属性与绑定

    let session: ChatSession
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionToDelete: ChatSession?
    @Binding var showDeleteSessionConfirm: Bool
    @Binding var folders: [SessionFolder]
    let tags: [SessionTag]
    let runtimeState: ConversationRuntimeSessionState?

    // MARK: - 操作

    let onOpenSession: (UUID) -> Void
    let onDeleteLastMessage: () -> Void
    let onSendSessionToCompanion: () -> Void
    let onMoveSessionToFolder: (UUID?) -> Void
    let onCreateTag: (String, SessionTagColor?) -> SessionTag?
    let onUpdateTag: (SessionTag, String, SessionTagColor?) -> Void
    let onDeleteTag: (SessionTag) -> Void
    let onSetTagIDs: ([UUID]) -> Void

    // MARK: - 环境

    @Environment(\.dismiss) private var dismiss
    @State private var relationshipDetails: WatchSessionRelationshipDetails?
    @State private var revokingContactID: UUID?

    private var folderByID: [UUID: SessionFolder] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
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

    // MARK: - 视图主体

    var body: some View {
        Form {
            Section {
                Button {
                    sessionToEdit = session
                    dismiss()
                } label: {
                    Label(NSLocalizedString("编辑话题", comment: ""), systemImage: "pencil")
                }

                NavigationLink {
                    WatchSessionTagAssignmentView(
                        session: session,
                        tags: tags,
                        onCreate: onCreateTag,
                        onUpdate: onUpdateTag,
                        onDelete: onDeleteTag,
                        onSetTagIDs: onSetTagIDs
                    )
                } label: {
                    Label(NSLocalizedString("标签", comment: "Session tags action"), systemImage: "tag")
                }

                Button {
                    sessionToBranch = session
                    showBranchOptions = true
                    dismiss()
                } label: {
                    Label(NSLocalizedString("创建分支", comment: ""), systemImage: "arrow.branch")
                }

                Button {
                    onSendSessionToCompanion()
                    dismiss()
                } label: {
                    Label(NSLocalizedString("发送到 iPhone", comment: ""), systemImage: "iphone")
                }

                if runtimeState?.runStatus == .pausedByBudget {
                    Button {
                        Task {
                            _ = await ChatService.shared.continueConversationRuntime(for: session.id)
                        }
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("继续运行", comment: "Continue conversation runtime"), systemImage: "play.circle")
                    }
                } else if let status = runtimeState?.runStatus, !status.isTerminal {
                    Button(role: .destructive) {
                        Task {
                            await ChatService.shared.stopConversationRuntime(for: session.id)
                        }
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("停止运行", comment: "Stop conversation runtime"), systemImage: "stop.circle")
                    }
                }
            }

            if let relationshipDetails {
                if let origin = relationshipDetails.origin {
                    Section(NSLocalizedString("创建来源", comment: "Conversation creation origin")) {
                        Button {
                            guard let parentSessionID = origin.parentSessionID else { return }
                            onOpenSession(parentSessionID)
                            dismiss()
                        } label: {
                            Label(origin.parentSessionNameSnapshot, systemImage: "arrow.up.left")
                        }
                        .disabled(origin.parentSessionID == nil)
                    }
                }

                if !relationshipDetails.children.isEmpty {
                    Section(NSLocalizedString("直接创建的会话", comment: "Directly created conversations")) {
                        ForEach(relationshipDetails.children) { child in
                            Button {
                                onOpenSession(child.id)
                                dismiss()
                            } label: {
                                Label(child.name, systemImage: "arrow.turn.down.right")
                            }
                        }
                    }
                }

                if !relationshipDetails.contacts.isEmpty {
                    Section(
                        header: Text(NSLocalizedString("联系授权", comment: "Linked conversation capabilities")),
                        footer: Text(NSLocalizedString("撤销后模型将不能再联系该会话，用户聊天不受影响。", comment: "Watch conversation capability footer"))
                    ) {
                        ForEach(relationshipDetails.contacts) { contact in
                            VStack(alignment: .leading) {
                                Text(contact.title)
                                Text(permissionSummary(for: contact))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Button(role: .destructive) {
                                revoke(contact)
                            } label: {
                                Label(
                                    NSLocalizedString("撤销授权", comment: "Revoke conversation capability"),
                                    systemImage: "person.crop.circle.badge.minus"
                                )
                            }
                            .disabled(revokingContactID != nil)
                        }
                    }
                }
            }

            Section(NSLocalizedString("移动到文件夹", comment: "")) {
                Button {
                    onMoveSessionToFolder(nil)
                    dismiss()
                } label: {
                    Label(NSLocalizedString("未分类", comment: ""), systemImage: session.folderID == nil ? "checkmark" : "tray")
                }

                ForEach(moveTargets) { target in
                    Button {
                        onMoveSessionToFolder(target.id)
                        dismiss()
                    } label: {
                        Label(target.title, systemImage: session.folderID == target.id ? "checkmark" : "folder")
                    }
                }
            }

            Section(NSLocalizedString("导出", comment: "")) {
                NavigationLink {
                    ChatExportFormatsView(
                        session: session,
                        messages: Persistence.loadMessages(for: session.id),
                        upToMessageID: nil
                    )
                } label: {
                    Label(NSLocalizedString("导出整个会话", comment: ""), systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button(role: .destructive) {
                    onDeleteLastMessage()
                    dismiss()
                } label: {
                    Label(NSLocalizedString("删除最后一条消息", comment: ""), systemImage: "delete.backward.fill")
                }
            }

            Section {
                Button(role: .destructive) {
                    sessionToDelete = session
                    showDeleteSessionConfirm = true
                    dismiss()
                } label: {
                    Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash.fill")
                }
            }

            Section(header: Text(NSLocalizedString("详细信息", comment: ""))) {
                if !sessionTags.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(NSLocalizedString("标签", comment: "Session tags info label"))
                            .etFont(.caption)
                            .foregroundColor(.secondary)
                        WatchSessionTagInlineList(tags: sessionTags)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(NSLocalizedString("会话 ID", comment: ""))
                        .etFont(.caption)
                        .foregroundColor(.secondary)
                    Text(session.id.uuidString)
                        .etFont(.caption2)
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) {
            await reloadRelationshipDetails()
        }
    }

    private var sessionTags: [SessionTag] {
        let tagByID = tags.reduce(into: [UUID: SessionTag]()) { result, tag in
            result[tag.id] = tag
        }
        return session.tagIDs.compactMap { tagByID[$0] }
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

    private func reloadRelationshipDetails() async {
        let sessionID = session.id
        relationshipDetails = await Task.detached(priority: .userInitiated) {
            let origins = Persistence.loadChildConversationOrigins(parentSessionID: sessionID)
            let namesByID = Dictionary(
                uniqueKeysWithValues: Persistence.loadChatSessions().map { ($0.id, $0.name) }
            )
            let children = origins.map { origin in
                WatchSessionRelationshipDetails.Child(
                    id: origin.childSessionID,
                    name: namesByID[origin.childSessionID]
                        ?? NSLocalizedString("未知会话", comment: "Unknown conversation")
                )
            }
            return WatchSessionRelationshipDetails(
                origin: Persistence.loadConversationOrigin(childSessionID: sessionID),
                children: children,
                contacts: Persistence.loadLinkedConversationContacts(sourceSessionID: sessionID)
            )
        }.value
    }

    private func revoke(_ contact: LinkedConversationContact) {
        revokingContactID = contact.id
        let sourceSessionID = session.id
        let targetSessionID = contact.sessionID
        Task {
            _ = await Task.detached(priority: .userInitiated) {
                Persistence.revokeConversationCapability(
                    sourceSessionID: sourceSessionID,
                    targetSessionID: targetSessionID
                )
            }.value
            revokingContactID = nil
            await reloadRelationshipDetails()
        }
    }

    private func permissionSummary(for contact: LinkedConversationContact) -> String {
        var permissions: [String] = []
        if contact.canRead {
            permissions.append(NSLocalizedString("读取", comment: "Conversation permission: read"))
        }
        if contact.canSend {
            permissions.append(NSLocalizedString("发送", comment: "Conversation permission: send"))
        }
        if contact.canTriggerReply {
            permissions.append(NSLocalizedString("触发回复", comment: "Conversation permission: trigger reply"))
        }
        if contact.canInterrupt {
            permissions.append(NSLocalizedString("停止运行", comment: "Conversation permission: interrupt"))
        }
        return permissions.joined(separator: NSLocalizedString("、", comment: "Localized list separator"))
    }
}
