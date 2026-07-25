// ============================================================================
// WatchSlashCommands.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件把已识别的 watchOS 斜杠命令映射到聊天页现有操作。
// ============================================================================

import SwiftUI
import ETOSCore

extension ContentView {
    func performWatchSlashCommand(_ command: ChatSlashCommand) {
        viewModel.userInput = ""

        switch command {
        case .new:
            viewModel.createNewSession()
        case .model:
            viewModel.activeSheet = nil
            settingsDestination = nil
            isSettingsPresented = true
            DispatchQueue.main.async {
                settingsDestination = .model
            }
        case .sessions:
            performWatchInputQuickAction(.sessionHistory)
        case .settings:
            performWatchInputQuickAction(.settings)
        case .tools:
            performWatchInputQuickAction(.toolCenter)
        case .daily:
            performWatchInputQuickAction(.dailyPulse)
        case .usage:
            performWatchInputQuickAction(.usageAnalytics)
        case .memory:
            performWatchInputQuickAction(.memory)
        case .mcp:
            performWatchInputQuickAction(.mcp)
        case .skills:
            performWatchInputQuickAction(.agentSkills)
        case .shortcuts:
            performWatchInputQuickAction(.shortcuts)
        case .roleplay:
            performWatchInputQuickAction(.roleplay)
        case .worldbook:
            performWatchInputQuickAction(.worldbook)
        case .features:
            performWatchInputQuickAction(.extendedFeatures)
        case .temporary:
            performWatchTemporaryChatSlashCommand()
        case .compact:
            guard viewModel.currentSession?.isTemporary == false,
                  !viewModel.allMessagesForSession.isEmpty || continuationContext != nil else {
                showUnavailableWatchSlashCommandNotice(
                    NSLocalizedString("当前会话没有可以压缩的对话内容。", comment: "No conversation content to compress")
                )
                return
            }
            isContextCompressionPresented = true
        case .retry:
            guard viewModel.canQuickRetryLatestMessage else {
                showUnavailableWatchSlashCommandNotice(
                    NSLocalizedString("当前没有可重试的回复。", comment: "No response available to retry")
                )
                return
            }
            shouldForceScrollToBottom = true
            shouldKeepBottomPinned = true
            viewModel.quickRetryLatestMessage()
        case .stop:
            guard viewModel.isSendingMessage || viewModel.isSendDelayPending else {
                showUnavailableWatchSlashCommandNotice(
                    NSLocalizedString("当前没有正在生成的回复。", comment: "No active response to stop")
                )
                return
            }
            viewModel.cancelSending()
        case .clear:
            viewModel.clearAllAttachments()
        }
    }

    private func performWatchTemporaryChatSlashCommand() {
        let isEnabled = viewModel.isTemporaryChatEnabled(for: viewModel.currentSession?.id)
        let isAvailable = TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: isEnabled,
            hasConversationStarted: !viewModel.allMessagesForSession.isEmpty || continuationContext != nil
        )
        guard isAvailable else {
            showUnavailableWatchSlashCommandNotice(
                NSLocalizedString("临时对话仅可在对话开始前开启。", comment: "Temporary chat slash command unavailable")
            )
            return
        }

        if isEnabled {
            viewModel.saveCurrentTemporarySession()
        } else {
            viewModel.enableTemporaryChat()
        }
        showChatTransientNotice(
            WatchChatTransientNotice(
                message: isEnabled
                    ? NSLocalizedString("临时对话已关闭", comment: "Watch temporary chat status")
                    : NSLocalizedString("临时对话已开启", comment: "Watch temporary chat status"),
                systemImage: isEnabled ? "eye" : "eye.slash",
                tint: isEnabled ? .secondary : .accentColor
            )
        )
    }

    private func showUnavailableWatchSlashCommandNotice(_ message: String) {
        showChatTransientNotice(
            WatchChatTransientNotice(
                message: message,
                systemImage: "exclamationmark.circle",
                tint: .orange
            )
        )
    }
}
