// ============================================================================
// WatchMessageRowView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS 聊天气泡行的渲染、滑动操作与权限状态判断。
// ============================================================================

import SwiftUI
import Shared

struct WatchMessageRowView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var toolPermissionCenter: ToolPermissionCenter

    let state: ChatMessageRenderState
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    let connectsTimelineFromPrevious: Bool
    let connectsTimelineToNext: Bool
    let isLiquidGlassEnabled: Bool
    let canRetry: Bool
    let onOpenMore: () -> Void

    private var message: ChatMessage {
        state.message
    }

    private var isReasoningExpandedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.reasoningExpandedState[message.id, default: false] },
            set: { viewModel.setReasoningExpanded($0, for: message.id) }
        )
    }

    private var isToolCallsExpandedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.toolCallsExpandedState[message.id, default: false] },
            set: { viewModel.toolCallsExpandedState[message.id] = $0 }
        )
    }

    private var showsStreamingIndicators: Bool {
        viewModel.isSendingMessage && viewModel.latestAssistantMessageID == message.id
    }

    private var hasActivePermission: Bool {
        guard let request = toolPermissionCenter.activeRequest,
              let toolCalls = message.toolCalls,
              !toolCalls.isEmpty else {
            return false
        }
        let normalizedRequestArguments = request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return toolCalls.contains { call in
            call.toolName == request.toolName
                && call.arguments.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedRequestArguments
        }
    }

    var body: some View {
        let bubble = ChatBubble(
            messageState: state,
            preparedMarkdownPayload: viewModel.preparedMarkdownByMessageID[message.id],
            preparedReasoningMarkdownPayload: viewModel.preparedReasoningMarkdownByMessageID[message.id],
            isReasoningExpanded: isReasoningExpandedBinding,
            isReasoningAutoPreview: viewModel.isAutoReasoningPreview(for: message.id),
            isToolCallsExpanded: isToolCallsExpandedBinding,
            enableMarkdown: viewModel.enableMarkdown,
            enableBackground: viewModel.enableBackground,
            enableLiquidGlass: isLiquidGlassEnabled,
            enableNoBubbleUI: viewModel.enableNoBubbleUI,
            enableAdvancedRenderer: viewModel.enableAdvancedRenderer,
            enableExperimentalToolResultDisplay: true,
            enableMathRendering: viewModel.isMathRenderingEnabled(for: message.id),
            showsStreamingIndicators: showsStreamingIndicators,
            mergeWithPrevious: mergeWithPrevious,
            mergeWithNext: mergeWithNext,
            connectsTimelineFromPrevious: connectsTimelineFromPrevious,
            connectsTimelineToNext: connectsTimelineToNext,
            hasAutoOpenedPendingToolCall: { toolCallID in
                viewModel.hasAutoOpenedPendingToolCall(toolCallID)
            },
            markPendingToolCallAutoOpened: { toolCallID in
                viewModel.markPendingToolCallAutoOpened(toolCallID)
            },
            onCodeBlockHeaderTap: { content in
                viewModel.appendCodeBlockContentToInput(content)
            },
            responseAttemptVersionInfo: viewModel.responseAttemptVersionInfo(for: message),
            canRetry: canRetry,
            onRetry: {
                viewModel.retryMessage(message)
            },
            onCopy: {
                viewModel.applyToolInputDraftRequest(
                    AppToolInputDraftRequest(text: message.content, mode: .replace)
                )
            },
            onSwitchToPreviousVersion: {
                viewModel.switchToPreviousVersion(of: message)
            },
            onSwitchToNextVersion: {
                viewModel.switchToNextVersion(of: message)
            },
            onOpenMore: hasActivePermission ? nil : onOpenMore
        )
        .id(state.id)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)

        if hasActivePermission {
            bubble
        } else {
            bubble.swipeActions(edge: .leading) {
                Button {
                    onOpenMore()
                } label: {
                    Label(NSLocalizedString("更多", comment: ""), systemImage: "ellipsis")
                }
                .tint(.gray)
            }
        }
    }
}
