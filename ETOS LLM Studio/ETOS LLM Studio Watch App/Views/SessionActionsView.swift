// ============================================================================
// SessionActionsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话操作菜单视图
//
// 功能特性:
// - 提供编辑话题、创建分支、同步删除等操作
// ============================================================================

import SwiftUI
import Shared

struct SessionActionsView: View {
    
    // MARK: - 属性与绑定
    
    let session: ChatSession
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionIndexToDelete: IndexSet?
    @Binding var showDeleteSessionConfirm: Bool
    @Binding var sessions: [ChatSession]
    
    // MARK: - 操作
    
    let onDeleteLastMessage: () -> Void

    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

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
                    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                        sessionIndexToDelete = IndexSet(integer: index)
                        showDeleteSessionConfirm = true
                        dismiss()
                    }
                } label: {
                    Label("删除会话", systemImage: "trash.fill")
                }
            }
            
            Section(header: Text("详细信息")) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("会话 ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(session.id.uuidString)
                        .font(.caption2)
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
