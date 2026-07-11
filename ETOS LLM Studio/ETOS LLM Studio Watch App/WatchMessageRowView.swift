// ============================================================================
// WatchMessageRowView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS 聊天气泡行的渲染、滑动操作与权限状态判断。
// ============================================================================

import SwiftUI
import WatchKit
import ETOSCore

struct WatchMessageRowView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var toolPermissionCenter: ToolPermissionCenter
    @ObservedObject private var appConfig = AppConfigStore.shared

    let state: ChatMessageRenderState
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    let messageActionBarContinuesToNext: Bool
    let connectsTimelineFromPrevious: Bool
    let connectsTimelineToNext: Bool
    let isLiquidGlassEnabled: Bool
    let canRetry: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
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

    private var responsiveReasoningPreviewMaxHeight: CGFloat {
        let screenHeight = max(1, WKInterfaceDevice.current().screenBounds.height)
        guard appConfig.enableResponsiveReasoningPreviewHeight else {
            let percent = appConfig.reasoningPreviewHeightPercent
            let safePercent = percent.isFinite ? max(0, percent) : 0
            return screenHeight * CGFloat(safePercent / 100)
        }
        let scaledHeight = screenHeight * 0.28
        return min(max(scaledHeight, 56), 72)
    }

    var body: some View {
        let bubble = ChatBubble(
            messageState: state,
            roleplaySessionID: viewModel.currentSession?.id,
            preparedMarkdownPayload: viewModel.preparedMarkdownByMessageID[message.id],
            preparedReasoningMarkdownPayload: viewModel.preparedReasoningMarkdownByMessageID[message.id],
            reasoningThinkingTitle: viewModel.reasoningThinkingTitleByMessageID[message.id],
            reasoningPreviewMaxHeight: responsiveReasoningPreviewMaxHeight,
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
            messageActionBarContinuesToNext: messageActionBarContinuesToNext,
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
                    AppToolInputDraftRequest(text: message.content, mode: .append)
                )
            },
            onSwitchToPreviousVersion: {
                viewModel.switchToPreviousVersion(of: message)
            },
            onSwitchToNextVersion: {
                viewModel.switchToNextVersion(of: message)
            },
            isSelectionMode: isSelectionMode,
            isSelected: isSelected,
            onToggleSelection: onToggleSelection,
            onOpenMore: hasActivePermission ? nil : onOpenMore,
            providers: viewModel.providers
        )
        .id(state.id)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)

        if hasActivePermission || isSelectionMode {
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
