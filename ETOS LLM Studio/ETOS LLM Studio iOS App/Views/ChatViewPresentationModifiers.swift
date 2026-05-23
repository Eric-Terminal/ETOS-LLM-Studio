// ============================================================================
// ChatViewPresentationModifiers.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天主界面的 Sheet、Dialog 与 Alert 修饰器。
// ============================================================================

import SwiftUI
import UIKit
import Shared

extension ChatView {
    func applyPresentationModifiers<Content: View>(to content: Content) -> some View {
        content
            .navigationDestination(item: $navigationDestination) { destination in
                switch destination {
                case .settings:
                    SettingsView()
                }
            }
            .sheet(item: $editingMessage) { message in
                NavigationStack {
                    EditMessageView(message: message) { updatedMessage in
                        viewModel.commitEditedMessage(updatedMessage)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $messageActionSheetPayload) { payload in
                MessageActionSheet(
                    payload: payload,
                    hasDisplayVersions: viewModel.hasDisplayVersions(for: payload.message),
                    displayVersionCount: viewModel.displayVersionCount(for: payload.message),
                    displayCurrentVersionIndex: viewModel.displayCurrentVersionIndex(for: payload.message),
                    canRetry: viewModel.canRetry(message: payload.message),
                    allMessages: viewModel.allMessagesForSession,
                    providers: viewModel.providers,
                    ttsManager: ttsManager,
                    onEdit: { message in
                        dismissMessageActionSheet {
                            editingMessage = message
                        }
                    },
                    onRetry: { message in
                        messageActionSheetPayload = nil
                        performDeferredRetry(message)
                    },
                    onShowFullError: { content in
                        dismissMessageActionSheet {
                            fullErrorContent = FullErrorContentPayload(content: content)
                        }
                    },
                    onBranch: { message in
                        dismissMessageActionSheet {
                            messageToBranch = message
                            showBranchOptions = true
                        }
                    },
                    onExport: { format, includeReasoning, upToMessage in
                        dismissMessageActionSheet {
                            exportConversation(format: format, includeReasoning: includeReasoning, upToMessage: upToMessage)
                        }
                    },
                    onSpeak: { message in
                        messageActionSheetPayload = nil
                        toggleSpeaking(message)
                    },
                    onSwitchVersion: { index, message in
                        viewModel.switchToVersion(index, of: message)
                        messageActionSheetPayload = nil
                    },
                    onDeleteVersion: { message, index in
                        dismissMessageActionSheet {
                            messageVersionToDelete = MessageVersionDeletePayload(message: message, index: index)
                        }
                    },
                    onDelete: { message in
                        dismissMessageActionSheet {
                            messageToDelete = message
                        }
                    },
                    onDownloadImages: { fileNames in
                        dismissMessageActionSheet {
                            Task {
                                await downloadImagesToPhotoLibrary(fileNames: fileNames)
                            }
                        }
                    },
                    onCopy: { message in
                        UIPasteboard.general.string = message.content
                        messageActionSheetPayload = nil
                    },
                    onJumpToMessage: { displayIndex in
                        jumpToMessage(displayIndex: displayIndex)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $fullErrorContent) { payload in
                FullErrorContentSheet(payload: payload)
            }
            .sheet(item: $sessionInfo) { info in
                SessionPickerInfoSheet(payload: info)
            }
            .sheet(item: $exportSharePayload) { payload in
                ActivityShareSheet(activityItems: [payload.fileURL])
            }
            .sheet(item: $activeChatPickerSheet, onDismiss: handleChatPickerSheetDismissed) { sheet in
                chatPickerSheet(for: sheet)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(NSLocalizedString("创建分支选项", comment: ""), isPresented: $showBranchOptions, titleVisibility: .visible) {
                Button(NSLocalizedString("仅复制消息历史", comment: "")) {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: false)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button(NSLocalizedString("复制消息历史和提示词", comment: "")) {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: true)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    messageToBranch = nil
                }
            } message: {
                if let message = messageToBranch, let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
                    Text(String(format: NSLocalizedString("将从第 %d 条消息处创建新的分支会话。", comment: ""), index + 1))
                }
            }
            .alert(NSLocalizedString("确认删除消息", comment: ""), isPresented: messageDeleteAlertPresented) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let message = messageToDelete {
                        viewModel.deleteAllVersions(of: message)
                    }
                    messageToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    messageToDelete = nil
                }
            } message: {
                Text(messageToDelete.map { viewModel.hasDisplayVersions(for: $0) } == true
                     ? NSLocalizedString("删除后将无法恢复这条消息的所有版本。", comment: "")
                     : NSLocalizedString("删除后无法恢复这条消息。", comment: ""))
            }
            .alert(NSLocalizedString("确认删除", comment: ""), isPresented: messageVersionDeleteAlertPresented) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let payload = messageVersionToDelete {
                        viewModel.deleteVersion(at: payload.index, of: payload.message)
                    }
                    messageVersionToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    messageVersionToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("删除后将无法恢复此版本的内容。", comment: ""))
            }
            .alert(NSLocalizedString("确认删除会话", comment: ""), isPresented: sessionDeleteAlertPresented) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let session = sessionToDelete {
                        viewModel.deleteSessions([session])
                    }
                    sessionToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("删除后所有消息也将被移除，操作不可恢复。", comment: ""))
            }
            .alert(NSLocalizedString("发现幽灵会话", comment: ""), isPresented: $showGhostSessionAlert) {
                Button(NSLocalizedString("删除幽灵", comment: ""), role: .destructive) {
                    if let session = ghostSession {
                        viewModel.deleteSessions([session])
                    }
                    ghostSession = nil
                }
                Button(NSLocalizedString("稍后处理", comment: ""), role: .cancel) {
                    ghostSession = nil
                }
            } message: {
                Text(NSLocalizedString("这个会话的消息文件已经丢失了，只剩下一个空壳在这里游荡。\n\n要帮它超度吗？", comment: ""))
            }
            .alert(NSLocalizedString("导出失败", comment: ""), isPresented: exportErrorAlertPresented) {
                Button(NSLocalizedString("确定", comment: ""), role: .cancel) {
                    exportErrorMessage = nil
                }
            } message: {
                Text(exportErrorMessage ?? "")
            }
            .alert(
                Text(NSLocalizedString("提示", comment: "Notice")),
                isPresented: imageDownloadAlertPresented
            ) {
                Button(NSLocalizedString("确定", comment: "OK"), role: .cancel) {}
            } message: {
                Text(imageDownloadAlertMessage ?? "")
            }
            .alert(
                Text(NSLocalizedString("记忆嵌入失败", comment: "Memory embedding failure alert title")),
                isPresented: $viewModel.showMemoryEmbeddingErrorAlert
            ) {
                Button(NSLocalizedString("好的", comment: "OK"), role: .cancel) {}
            } message: {
                Text(viewModel.memoryEmbeddingErrorMessage)
            }
    }
}
