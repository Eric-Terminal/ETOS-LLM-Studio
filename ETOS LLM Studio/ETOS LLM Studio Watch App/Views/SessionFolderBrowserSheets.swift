// ============================================================================
// SessionFolderBrowserSheets.swift
// ============================================================================
// ETOS LLM Studio Watch App 文件夹浏览器弹窗与操作面板
// ============================================================================

import Foundation
import Shared
import SwiftUI

extension SessionFolderBrowserView {
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
}
