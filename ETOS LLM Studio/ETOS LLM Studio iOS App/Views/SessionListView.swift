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
    
    @State private var editingSessionID: UUID?
    @State private var draftName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var sessionsToDelete: [ChatSession] = []
    @State private var sessionInfo: SessionInfoPayload?
    @State private var showGhostSessionAlert = false
    @State private var ghostSession: ChatSession?
    
    var body: some View {
        List {
            Section {
                Button {
                    viewModel.createNewSession()
                    focusOnLatest()
                } label: {
                    Label("开启新对话", systemImage: "plus.circle.fill")
                }
            }
            
            Section("会话") {
                ForEach(viewModel.chatSessions) { session in
                    SessionRow(
                        session: session,
                        isCurrent: session.id == viewModel.currentSession?.id,
                        isEditing: editingSessionID == session.id,
                        draftName: editingSessionID == session.id ? $draftName : .constant(session.name),
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
                            sessionsToDelete = [session]
                            showDeleteConfirmation = true
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
                        }
                    )
                }
                .onDelete { indexSet in
                    let toDelete = indexSet.map { viewModel.chatSessions[$0] }
                    sessionsToDelete = toDelete
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("会话管理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        .alert("确认删除会话", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) {
                viewModel.deleteSessions(sessionsToDelete)
                sessionsToDelete.removeAll()
            }
            Button("取消", role: .cancel) {
                sessionsToDelete.removeAll()
            }
        } message: {
            Text("删除后所有消息也将被移除，操作不可恢复。")
        }
        .sheet(item: $sessionInfo) { info in
            SessionInfoSheet(payload: info)
        }
        .alert("👻 发现幽灵会话", isPresented: $showGhostSessionAlert) {
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
        let messageFile = Persistence.getChatsDirectory().appendingPathComponent("\(session.id.uuidString).json")
        
        // 检查消息文件是否存在
        if !FileManager.default.fileExists(atPath: messageFile.path) {
            // 发现幽灵会话！
            ghostSession = session
            showGhostSessionAlert = true
        } else {
            viewModel.setCurrentSession(session)
        }
    }
    
    private func focusOnLatest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editingSessionID = viewModel.currentSession?.id
            draftName = viewModel.currentSession?.name ?? ""
        }
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isEditing: Bool
    @Binding var draftName: String
    
    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    
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
                        if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    if isCurrent {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 70, height: 26)
                            .overlay(
                                Label("当前", systemImage: "checkmark")
                                    .font(.footnote.bold())
                                    .foregroundColor(.accentColor)
                            )
                    }
                    
                    Button {
                        onInfo()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("查看会话信息")
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
