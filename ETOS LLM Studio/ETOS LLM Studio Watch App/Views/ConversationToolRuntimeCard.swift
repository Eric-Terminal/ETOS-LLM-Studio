// ============================================================================
// ConversationToolRuntimeCard.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 会话工具摘要。所有按钮显式使用 borderless，避免消息 List 的整行
// 点击判定吞并独立操作。
// ============================================================================

import Combine
import ETOSCore
import Foundation
import SwiftUI

struct ConversationToolRuntimeCard: View {
    let toolCall: InternalToolCall
    let onOpenConversation: ((UUID) -> Void)?

    @State private var targets: [ConversationToolTargetPresentation] = []

    var body: some View {
        Group {
            if !targets.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(targets) { target in
                        VStack(alignment: .leading) {
                            Label(target.title, systemImage: "bubble.left.and.bubble.right")
                                .etFont(.caption.weight(.semibold))
                                .lineLimit(2)

                            if let runStatus = target.runStatus {
                                Text(runtimeStatusText(runStatus))
                                    .etFont(.caption2)
                                    .foregroundStyle(runtimeStatusColor(runStatus))
                            }

                            if let preview = target.replyPreview {
                                Text(preview)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }

                            Button {
                                onOpenConversation?(target.sessionID)
                            } label: {
                                Label(NSLocalizedString("打开会话", comment: "Open conversation tool target"), systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.borderless)
                            .disabled(onOpenConversation == nil)

                            if let runStatus = target.runStatus, !runStatus.isTerminal {
                                Button(role: .destructive) {
                                    stop(target.sessionID)
                                } label: {
                                    Label(NSLocalizedString("停止运行", comment: "Stop conversation run"), systemImage: "stop.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        if target.id != targets.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.top)
            }
        }
        .task(id: reloadIdentity) {
            await reloadTargets()
        }
        .onReceive(ChatService.shared.conversationRuntimeStatesSubject) { _ in
            Task { await reloadTargets() }
        }
    }

    private var reloadIdentity: String {
        "\(toolCall.id)#\(toolCall.result ?? "")"
    }

    private func stop(_ sessionID: UUID) {
        Task {
            await ChatService.shared.stopConversationRuntime(for: sessionID)
            await reloadTargets()
        }
    }

    private func reloadTargets() async {
        let currentToolCall = toolCall
        let loadedTargets = await Task.detached(priority: .utility) {
            ConversationToolPresentationLoader.loadTargets(for: currentToolCall)
        }.value
        guard !Task.isCancelled else { return }
        targets = loadedTargets
    }

    private func runtimeStatusText(_ status: ConversationRunStatus) -> String {
        switch status {
        case .queued: return NSLocalizedString("排队中", comment: "Conversation run queued")
        case .running: return NSLocalizedString("运行中", comment: "Conversation run running")
        case .waitingTool: return NSLocalizedString("等待工具", comment: "Conversation run waiting for tool")
        case .waitingConversation: return NSLocalizedString("等待会话", comment: "Conversation run waiting for conversation")
        case .waitingUser: return NSLocalizedString("等待用户", comment: "Conversation run waiting for user")
        case .completed: return NSLocalizedString("已完成", comment: "Conversation run completed")
        case .failed: return NSLocalizedString("失败", comment: "Conversation run failed")
        case .cancelled: return NSLocalizedString("已取消", comment: "Conversation run cancelled")
        case .interrupted: return NSLocalizedString("已中断", comment: "Conversation run interrupted")
        case .pausedByBudget: return NSLocalizedString("已暂停", comment: "Conversation run paused")
        }
    }

    private func runtimeStatusColor(_ status: ConversationRunStatus) -> Color {
        switch status {
        case .failed, .interrupted:
            return .red
        case .pausedByBudget:
            return .orange
        case .completed:
            return .green
        case .queued, .running, .waitingTool, .waitingConversation, .waitingUser, .cancelled:
            return .secondary
        }
    }
}
