// ============================================================================
// SessionActionsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话操作菜单视图
//
// 功能特性:
// - 提供编辑话题、创建分支、移动文件夹、同步删除等操作
// ============================================================================

import SwiftUI
import Shared

struct SessionActionsView: View {

    // MARK: - 属性与绑定

    let session: ChatSession
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionToDelete: ChatSession?
    @Binding var showDeleteSessionConfirm: Bool
    @Binding var folders: [SessionFolder]

    // MARK: - 操作

    let onDeleteLastMessage: () -> Void
    let onSendSessionToCompanion: () -> Void
    let onMoveSessionToFolder: (UUID?) -> Void

    // MARK: - 环境

    @Environment(\.dismiss) var dismiss

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
                    Label("编辑话题", systemImage: "pencil")
                }

                Button {
                    sessionToBranch = session
                    showBranchOptions = true
                    dismiss()
                } label: {
                    Label("创建分支", systemImage: "arrow.branch")
                }

                Button {
                    onSendSessionToCompanion()
                    dismiss()
                } label: {
                    Label("发送到 iPhone", systemImage: "iphone")
                }
            }

            Section("移动到文件夹") {
                Button {
                    onMoveSessionToFolder(nil)
                    dismiss()
                } label: {
                    Label("未分类", systemImage: session.folderID == nil ? "checkmark" : "tray")
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

            Section("导出") {
                NavigationLink {
                    ChatExportFormatsView(
                        session: session,
                        messages: Persistence.loadMessages(for: session.id),
                        upToMessageID: nil
                    )
                } label: {
                    Label("导出整个会话", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button(role: .destructive) {
                    onDeleteLastMessage()
                    dismiss()
                } label: {
                    Label("删除最后一条消息", systemImage: "delete.backward.fill")
                }
            }

            Section {
                Button(role: .destructive) {
                    sessionToDelete = session
                    showDeleteSessionConfirm = true
                    dismiss()
                } label: {
                    Label("删除会话", systemImage: "trash.fill")
                }
            }

            Section(header: Text("详细信息")) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("会话 ID")
                        .etFont(.caption)
                        .foregroundColor(.secondary)
                    Text(session.id.uuidString)
                        .etFont(.caption2)
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
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

private struct SessionMoveTarget: Identifiable {
    let id: UUID
    let title: String
}
