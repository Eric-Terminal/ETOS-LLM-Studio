// ============================================================================
// ChatViewInputBar.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 底部输入栏在普通聊天与工具问答输入之间的切换。
// ============================================================================

import SwiftUI
import Shared

extension ChatView {
    /// Telegram 风格输入栏
    @ViewBuilder
    var telegramInputBar: some View {
        if let request = viewModel.activeAskUserInputRequest {
            AskUserInputComposerPanel(
                request: request,
                submitAction: { answers in
                    composerFocused = false
                    appConfig.composerDraft = ""
                    viewModel.submitAskUserInputAnswers(answers, for: request)
                },
                cancelAction: {
                    composerFocused = false
                    appConfig.composerDraft = ""
                    viewModel.cancelAskUserInputRequest(using: request)
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6 - tabBarCompensation)
        } else {
            TelegramMessageComposer(
                text: Binding(
                    get: { appConfig.composerDraft },
                    set: { newValue in
                        appConfig.composerDraft = newValue
                        viewModel.userInput = newValue
                    }
                ),
                isSending: viewModel.isSendingMessage,
                sendAction: {
                    guard viewModel.canSendMessage else { return }
                    viewModel.sendMessage()
                    appConfig.composerDraft = ""
                },
                stopAction: {
                    viewModel.cancelSending()
                },
                focus: $composerFocused
            )
            .onAppear {
                viewModel.userInput = appConfig.composerDraft
            }
            .padding(.bottom, -tabBarCompensation)
        }
    }
}
