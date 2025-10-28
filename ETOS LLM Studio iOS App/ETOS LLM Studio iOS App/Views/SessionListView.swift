// ============================================================================
// SessionListView.swift
// ============================================================================
// 会话管理界面 (iOS)
// - 展示所有会话并支持快速切换
// - 支持内联重命名、分支、导出与删除
// ============================================================================

import SwiftUI
import Shared

struct SessionListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    
    @State private var editingSessionID: UUID?
    @State private var draftName: String = ""
    @State private var sessionToExport: ChatSession?
    @State private var showDeleteConfirmation = false
    @State private var sessionsToDelete: [ChatSession] = []
    
    var body: some View {
        NavigationStack {
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
                        viewModel.setCurrentSession(session)
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
                    onExport: {
                        sessionToExport = session
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
                    }
                )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                sessionsToDelete = [session]
                                showDeleteConfirmation = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
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
            .sheet(item: $sessionToExport) { session in
                ExportView(session: session) { sess, ip, completion in
                    viewModel.exportSessionViaNetwork(session: sess, ipAddress: ip, completion: completion)
                }
            }
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
    let onExport: () -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    
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
                HStack {
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
                onExport()
            } label: {
                Label("导出到电脑", systemImage: "wifi")
            }
            
            Button {
                onDeleteLastMessage()
            } label: {
                Label("删除最后一条消息", systemImage: "delete.backward")
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
