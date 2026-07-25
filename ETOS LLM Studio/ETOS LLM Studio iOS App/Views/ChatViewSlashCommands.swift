// ============================================================================
// ChatViewSlashCommands.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件把已识别的 iOS 斜杠命令映射到聊天页现有操作。
// ============================================================================

import SwiftUI
import ETOSCore

extension ChatView {
    func performSlashCommand(_ command: ChatSlashCommand) {
        draftText = ""
        viewModel.userInput = ""

        switch command {
        case .new:
            composerFocused = false
            viewModel.createNewSession()
        case .model:
            composerFocused = false
            presentModelPickerSheet()
        case .sessions:
            composerFocused = false
            if usesLandscapeSessionSidebar {
                withAnimation(chatPickerAnimation) {
                    isLandscapeSessionSidebarPresented = true
                }
            } else {
                presentSessionPicker()
            }
        case .settings:
            presentSlashCommandDestination(.settings)
        case .tools:
            presentSlashCommandDestination(.toolCenter)
        case .daily:
            presentSlashCommandDestination(.dailyPulse)
        case .usage:
            presentSlashCommandDestination(.usageAnalytics)
        case .memory:
            presentSlashCommandDestination(.memory)
        case .mcp:
            presentSlashCommandDestination(.mcp)
        case .skills:
            presentSlashCommandDestination(.agentSkills)
        case .shortcuts:
            presentSlashCommandDestination(.shortcuts)
        case .roleplay:
            presentSlashCommandDestination(.roleplay)
        case .worldbook:
            presentSlashCommandDestination(.worldbook)
        case .features:
            presentSlashCommandDestination(.extendedFeatures)
        case .temporary:
            performTemporaryChatSlashCommand()
        case .compact:
            performContextCompressionSlashCommand()
        case .retry:
            guard viewModel.canQuickRetryLatestMessage else {
                showUnavailableSlashCommandNotice(
                    NSLocalizedString("当前没有可重试的回复。", comment: "No response available to retry")
                )
                return
            }
            viewModel.quickRetryLatestMessage()
        case .stop:
            guard viewModel.isSendingMessage || viewModel.isSendDelayPending else {
                showUnavailableSlashCommandNotice(
                    NSLocalizedString("当前没有正在生成的回复。", comment: "No active response to stop")
                )
                return
            }
            viewModel.cancelSending()
        case .clear:
            viewModel.clearAllAttachments()
        }
    }

    private func presentSlashCommandDestination(_ destination: ChatQuickAction) {
        composerFocused = false
        navigationDestination = destination
    }

    private func performTemporaryChatSlashCommand() {
        guard isQuickActionAvailable(.temporaryChat) else {
            showUnavailableSlashCommandNotice(
                NSLocalizedString("临时对话仅可在对话开始前开启。", comment: "Temporary chat slash command unavailable")
            )
            return
        }
        setTemporaryChatEnabled(!isTemporaryChatEnabled)
    }

    private func performContextCompressionSlashCommand() {
        guard let session = viewModel.currentSession,
              !session.isTemporary,
              !viewModel.allMessagesForSession.isEmpty || continuationContext != nil else {
            showUnavailableSlashCommandNotice(
                NSLocalizedString("当前会话没有可以压缩的对话内容。", comment: "No conversation content to compress")
            )
            return
        }
        composerFocused = false
        contextCompressionSourceSession = session
    }

    private func showUnavailableSlashCommandNotice(_ message: String) {
        showChatTransientNotice(
            ChatTransientNotice(
                message: message,
                systemImage: "exclamationmark.circle",
                tint: .orange
            )
        )
    }
}
