// ============================================================================
// ChatViewInputBar.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 底部输入栏在普通聊天与工具问答输入之间的切换。
// ============================================================================

import SwiftUI
import ETOSCore

extension ChatView {
    /// Telegram 风格输入栏
    @ViewBuilder
    var telegramInputBar: some View {
        if let request = viewModel.activeAskUserInputRequest {
            AskUserInputComposerPanel(
                request: request,
                submitAction: { answers in
                    composerFocused = false
                    draftText = ""
                    viewModel.submitAskUserInputAnswers(answers, for: request)
                },
                cancelAction: {
                    composerFocused = false
                    draftText = ""
                    viewModel.cancelAskUserInputRequest(using: request)
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6 - tabBarCompensation)
        } else {
            TelegramMessageComposer(
                text: Binding(
                    get: { draftText },
                    set: { newValue in
                        draftText = newValue
                        viewModel.userInput = newValue
                    }
                ),
                isSending: viewModel.isSendingMessage,
                sendAction: {
                    guard viewModel.canSendMessage else { return }
                    if AppConfigStore.shared.chatSendAnimationEnabled {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                            viewModel.sendMessage()
                        }
                    } else {
                        viewModel.sendMessage()
                    }
                    draftText = ""
                },
                stopAction: {
                    viewModel.cancelSending()
                },
                focus: $composerFocused
            )
            .onReceive(viewModel.$userInput) { newValue in
                guard draftText != newValue else { return }
                draftText = newValue
            }
            .onAppear {
                if viewModel.userInput.isEmpty {
                    viewModel.userInput = draftText
                } else if draftText != viewModel.userInput {
                    draftText = viewModel.userInput
                }
            }
            .padding(.bottom, -tabBarCompensation)
        }
    }
}
