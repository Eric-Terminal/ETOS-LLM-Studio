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
    let onSessionSelected: (ChatSession) -> Void
    let updateSessionAction: (ChatSession) -> Void
    
    // MARK: - 状态
    
    @State private var showDeleteSessionConfirm: Bool = false
    @State private var sessionIndexToDelete: IndexSet?
    @State private var sessionToEdit: ChatSession?
    @State private var showBranchOptions: Bool = false
    @State private var sessionToBranch: ChatSession?
    
    // MARK: - 视图主体
    
    var body: some View {
        List {
            ForEach(sessions) {
                session in 
                SessionRowView(
                    session: session,
                    currentSession: $currentSession,
                    sessions: $sessions,
                    sessionToEdit: $sessionToEdit,
                    sessionToBranch: $sessionToBranch,
                    showBranchOptions: $showBranchOptions,
                    sessionIndexToDelete: $sessionIndexToDelete,
                    showDeleteSessionConfirm: $showDeleteSessionConfirm,
                    onSessionSelected: onSessionSelected,
                    deleteLastMessageAction: deleteLastMessageAction
                )
            }
        }
        .navigationTitle("历史会话")
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
    
    // MARK: 操作
    
    let onSessionSelected: (ChatSession) -> Void
    let deleteLastMessageAction: (ChatSession) -> Void

    // MARK: 视图主体
    
    var body: some View {
        Button(action: { onSessionSelected(session) }) {
            HStack {
                MarqueeText(content: session.name, uiFont: .preferredFont(forTextStyle: .headline))
                    .foregroundColor(.primary)
                    .allowsHitTesting(false) // 修复 Bug #1：让点击可以“穿透”滚动文本

                if currentSession?.id == session.id {
                    Spacer()
                    Image(systemName: "checkmark")
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
                    onDeleteLastMessage: { deleteLastMessageAction(session) }
                )
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .tint(.gray)
        }
    }
}
