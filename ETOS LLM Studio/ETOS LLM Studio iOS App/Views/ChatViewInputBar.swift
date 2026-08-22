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
    @MainActor
    func reloadCurrentLocalAgentMode() async {
        guard let sessionID = viewModel.currentSession?.id else {
            currentLocalAgentMode = .chat
            return
        }

        let selectionRevision = localAgentModeSelectionRevision
        await viewModel.chatService.waitForInitialPersistenceStateIfNeeded()
        guard !Task.isCancelled,
              viewModel.currentSession?.id == sessionID,
              localAgentModeSelectionRevision == selectionRevision else { return }

        let storedMode = await Task.detached(priority: .userInitiated) {
            Persistence.localAgentMode(sessionID: sessionID)
        }.value
        // 用户在异步读取期间做出的选择优先，旧快照不能把 Agent 悄悄改回 Chat。
        guard !Task.isCancelled,
              viewModel.currentSession?.id == sessionID,
              localAgentModeSelectionRevision == selectionRevision else { return }
        currentLocalAgentMode = storedMode
    }

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
                isRequestControlsExpanded: $isComposerRequestControlsExpanded,
                localAgentMode: Binding(
                    get: { currentLocalAgentMode },
                    set: { mode in
                        guard currentLocalAgentMode != mode else { return }
                        localAgentModeSelectionRevision &+= 1
                        currentLocalAgentMode = mode
                    }
                ),
                isSending: viewModel.isSendingMessage
                    || viewModel.isSendDelayPending
                    || viewModel.isSendSubmissionPending,
                isSendActionPending: viewModel.isSendSubmissionPending,
                sendAction: {
                    guard viewModel.canSendMessage else { return }
                    shouldKeepBottomPinned = true
                    showScrollToBottom = false
                    let outgoingText = draftText
                    if AppConfigStore.shared.chatSendAnimationEnabled,
                       AppConfigStore.shared.chatSendDelaySeconds <= 0 {
                        // 启动「输入框 → 气泡」Overlay 飞行（内部已调用 viewModel.sendMessage()）
                        beginSendFlight(
                            text: outgoingText,
                            localAgentMode: currentLocalAgentMode
                        )
                    } else {
                        viewModel.sendMessage(localAgentMode: currentLocalAgentMode)
                    }
                    draftText = ""
                },
                stopAction: {
                    viewModel.cancelSending()
                },
                slashCommandAction: performSlashCommand,
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

    /// 收起键盘和输入栏临时面板；外部点击只改变输入状态，不触发消息内容。
    func dismissComposerInput() {
        composerFocused = false
        guard isComposerRequestControlsExpanded else { return }
        let animation: Animation = accessibilityReduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.94)
        withAnimation(animation) {
            isComposerRequestControlsExpanded = false
        }
    }
}
