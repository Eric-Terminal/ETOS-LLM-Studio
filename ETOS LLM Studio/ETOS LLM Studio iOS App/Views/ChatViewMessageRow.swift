// ============================================================================
// ChatViewMessageRow.swift
// ============================================================================
// 历史懒布局和立即布局的尾行共用同一套消息气泡、交互与几何上报。
// ============================================================================

import ETOSCore
import Foundation
import SwiftUI
import UIKit

extension ChatView {
    @ViewBuilder
    func chatMessageRow(
        index: Int,
        displayedMessages: [ChatMessageRenderState],
        sessionMessages: [ChatMessage],
        retryableMessageIDs: Set<UUID>,
        layoutWidth: CGFloat,
        reasoningPreviewMaxHeight: CGFloat
    ) -> some View {
        let state = displayedMessages[index]
        let message = state.message
        let previousMessage = index > 0 ? displayedMessages[index - 1].message : nil
        let nextMessage = index + 1 < displayedMessages.count ? displayedMessages[index + 1].message : nil
        let mergeWithPrevious = shouldMergeTurnMessages(previousMessage, with: message)
        let mergeWithNext = shouldMergeTurnMessages(message, with: nextMessage)
        let messageActionBarContinuesToNext = shouldContinueMessageActionBar(message, with: nextMessage)
        let connectsTimelineFromPrevious = shouldConnectTimeline(previousMessage, with: message)
        let connectsTimelineToNext = shouldConnectTimeline(message, with: nextMessage)
        let showsStreamingIndicators = viewModel.isActivelyStreaming(message)
        // 贴底流式气泡只跟随真实滚动偏移，避免相位弹簧与吸底校正互相拉扯。
        let isBottomPinnedStreamingBubble = showsStreamingIndicators && scrollCoordinator.shouldKeepBottomPinned
        let sendFlightTarget = self.sendFlightTarget(for: message.id)
        let reportsSendFlightTarget = sendFlightTarget != nil
        let sendFlightOpacity = sendFlightMessageOpacity(for: message)
        let preparedMarkdownPayload = viewModel.preparedMarkdownByMessageID[message.id]
        let preparedReasoningMarkdownPayload = viewModel.preparedReasoningMarkdownByMessageID[message.id]
        let layoutIntegrityMetadata: ChatMessageLayoutMetadata? = if
            shouldReportChatViewportLayoutFrames
        {
            ChatMessageLayoutMetadata(
                role: message.role.rawValue,
                contentUTF8Length: preparedMarkdownPayload?.sourceUTF8Length ?? 0,
                reasoningUTF8Length:
                    preparedReasoningMarkdownPayload?.sourceUTF8Length ?? 0,
                isAwaitingStaticHandoff: state.streamingMarkdownState
                    .isAwaitingStaticHandoff(channel: .content)
                    || state.streamingMarkdownState
                        .isAwaitingStaticHandoff(channel: .reasoning),
                hasPreparedMarkdown: preparedMarkdownPayload != nil,
                hasPreparedReasoningMarkdown: preparedReasoningMarkdownPayload != nil,
                layoutRevision: state.layoutRevision,
                recoveryRevision: scrollCoordinator.chatLayoutIntegrityMonitor.recoveryRevision(for: message.id),
                rendererHandoffRevision: state.rendererHandoffRevision,
                rendererHandoffAt: state.lastRendererHandoffAt,
                usesNoBubbleStyle: viewModel.enableNoBubbleUI
                    && message.role != .error
                    && !(message.role == .user && message.authorKind == .user),
                contentRenderer: ChatBubbleRendererIdentity.resolved(
                    hasContent: !message.content.isEmpty,
                    enableMarkdown: viewModel.enableMarkdown,
                    isStreaming: showsStreamingIndicators,
                    isAwaitingStaticHandoff: state.streamingMarkdownState
                        .isAwaitingStaticHandoff(channel: .content),
                    hasPreparedMarkdown: preparedMarkdownPayload != nil,
                    usesWebRenderer: viewModel.enableAdvancedRenderer
                        && preparedMarkdownPayload?.containsMermaidContent == true,
                    hasRoleplayHTML: state.roleplayHTML?.containsHTML == true
                ),
                reasoningRenderer: ChatBubbleRendererIdentity.resolved(
                    hasContent: !(message.reasoningContent?.isEmpty ?? true),
                    enableMarkdown: viewModel.enableMarkdown,
                    isStreaming: showsStreamingIndicators,
                    isAwaitingStaticHandoff: state.streamingMarkdownState
                        .isAwaitingStaticHandoff(channel: .reasoning),
                    hasPreparedMarkdown: preparedReasoningMarkdownPayload != nil,
                    usesWebRenderer: viewModel.enableAdvancedRenderer
                        && preparedReasoningMarkdownPayload?.containsMermaidContent == true
                ),
                layoutWidthBucket: ChatBubbleLayoutIdentity.widthBucket(
                    for: layoutWidth
                )
            )
        } else {
            nil
        }
        ChatBubble(
            messageState: state,
            roleplaySessionID: viewModel.currentSession?.id,
            roleplayMessages: sessionMessages,
            layoutWidth: layoutWidth,
            reasoningPreviewMaxHeight: reasoningPreviewMaxHeight,
            preparedMarkdownPayload: preparedMarkdownPayload,
            preparedReasoningMarkdownPayload: preparedReasoningMarkdownPayload,
            reasoningThinkingTitle: viewModel.reasoningThinkingTitleByMessageID[message.id],
            isReasoningExpanded: Binding(
                get: { viewModel.reasoningExpandedState[message.id, default: false] },
                set: { isExpanded in
                    viewModel.setReasoningExpanded(isExpanded, for: message.id)
                    if isExpanded {
                        scrollCoordinator.shouldKeepBottomPinned = false
                    }
                }
            ),
            isReasoningAutoPreview: viewModel.isAutoReasoningPreview(for: message.id),
            isToolCallsExpanded: Binding(
                get: { viewModel.toolCallsExpandedState[message.id, default: false] },
                set: { isExpanded in
                    viewModel.toolCallsExpandedState[message.id] = isExpanded
                    if isExpanded {
                        scrollCoordinator.shouldKeepBottomPinned = false
                    }
                }
            ),
            enableMarkdown: viewModel.enableMarkdown,
            enableBackground: viewModel.enableBackground,
            enableLiquidGlass: isLiquidGlassEnabled,
            enableNoBubbleUI: viewModel.enableNoBubbleUI,
            enableAdvancedRenderer: viewModel.enableAdvancedRenderer,
            enableExperimentalToolResultDisplay: true,
            enableMathRendering: viewModel.enableAdvancedRenderer,
            isCurrentResponse: viewModel.isSendingMessage
                && viewModel.latestAssistantMessageID == state.id,
            mergeWithPrevious: mergeWithPrevious,
            mergeWithNext: mergeWithNext,
            messageActionBarContinuesToNext: messageActionBarContinuesToNext,
            connectsTimelineFromPrevious: connectsTimelineFromPrevious,
            connectsTimelineToNext: connectsTimelineToNext,
            responseAttemptVersionInfo: viewModel.responseAttemptVersionInfo(for: message),
            hasAutoOpenedPendingToolCall: { toolCallID in
                viewModel.hasAutoOpenedPendingToolCall(toolCallID)
            },
            markPendingToolCallAutoOpened: { toolCallID in
                viewModel.markPendingToolCallAutoOpened(toolCallID)
            },
            canRetry: retryableMessageIDs.contains(message.id),
            onRetry: {
                performDeferredRetry(message)
            },
            onCopy: {
                UIPasteboard.general.string = state.message.content
            },
            onSwitchToPreviousVersion: {
                viewModel.switchToPreviousVersion(of: message)
            },
            onSwitchToNextVersion: {
                viewModel.switchToNextVersion(of: message)
            },
            isSelectionMode: isMessageSelectionMode,
            isSelected: selectedMessageIDs.contains(message.id),
            onToggleSelection: {
                toggleMessageSelection(message.id)
            },
            onOpenMore: { latestMessage in
                messageActionSheetPayload = MessageActionSheetPayload(message: latestMessage)
            },
            onOpenFullContent: { latestMessage in
                fullMessageContentTarget = latestMessage
            },
            onDownloadImageAttachment: { fileName in
                Task {
                    await downloadImagesToPhotoLibrary(fileNames: [fileName])
                }
            },
            onDeleteImageAttachment: { fileName in
                viewModel.removeImageAttachment(
                    fileName: fileName,
                    fromMessageID: message.id
                )
            },
            sourceConversationName: message.sourceSessionID.flatMap { sourceSessionID in
                viewModel.chatSessions.first(where: { $0.id == sourceSessionID })?.name
            },
            onOpenSourceConversation: message.sourceSessionID.map { sourceSessionID in
                { _ = viewModel.setCurrentSessionIfExists(sessionID: sourceSessionID) }
            },
            onOpenConversation: { sessionID in
                _ = viewModel.setCurrentSessionIfExists(sessionID: sessionID)
            },
            sendFlightTarget: sendFlightTarget,
            sendFlightContentOpacity: reportsSendFlightTarget ? sendFlightOpacity : 1,
            reportsLayoutIntegrityFrame: scrollCoordinator.chatLayoutIntegrityMonitor
                .isContentFrameProbeActive,
            layoutRecoveryRevision: scrollCoordinator.chatLayoutIntegrityMonitor.recoveryRevision(
                for: message.id
            ),
            providers: viewModel.providers
        )
        .background {
            ZStack {
                ChatHistoryAnchorFrameReporter(messageID: message.id)
                if let layoutIntegrityMetadata {
                    ChatMessageLayoutFrameReporter(
                        messageID: message.id,
                        metadata: layoutIntegrityMetadata,
                        probeRevision: scrollCoordinator.chatLayoutIntegrityMonitor.layoutProbeRevision,
                        stackRecoveryRevision: scrollCoordinator.chatLayoutIntegrityMonitor.stackRecoveryRevision
                    )
                }
            }
        }
        // 发送入场动画：用户气泡走 Overlay 飞行（见 flightOverlayLayer），
        // 真实气泡在飞行期间无动画隐身，避免两份白字文本叠加。
        .transition(
            message.role == .user && flightState != nil
            ? .identity
            : .asymmetric(
                insertion: .move(edge: .bottom)
                    .combined(with: .scale(scale: 0.92, anchor: .bottomLeading))
                    .combined(with: .opacity),
                removal: .opacity
            )
        )
        // 精确来源在气泡内部仅隐藏实际内容，保持共同 carrier 可见；同轮回复仍整行显隐。
        .opacity(reportsSendFlightTarget ? 1 : sendFlightOpacity)
        .allowsHitTesting(sendFlightOpacity > 0)
        .accessibilityHidden(sendFlightOpacity == 0)
        .id(ChatScrollTargetID.message(state.id))
        // iMessage 风格滚动波浪：纯位置偏移驱动弹性交错
        .scrollTransition(
            topLeading: .animated(.smooth(duration: 0.4)),
            bottomTrailing: .animated(.spring(
                response: appConfig.chatScrollAnimationSpringResponse,
                dampingFraction: appConfig.chatScrollAnimationSpringDamping
            ))
        ) { [scrollAnimEnabled = appConfig.chatScrollAnimationEnabled && !accessibilityReduceMotion,
             scrollAnimOffset = appConfig.chatScrollAnimationOffset,
             layoutSettling = scrollCoordinator.isChatLayoutSettling,
             keepsBottomPinned = scrollCoordinator.shouldKeepBottomPinned,
             scrollUserInteracting = scrollCoordinator.isChatScrollUserInteracting,
             timelineNavigationActive = appConfig.chatTimelineNavigationEnabled
                && (hasChatProgrammaticScrollOwnership
                    || scrollCoordinator.messageNavigationCursorID != nil)] content, phase in
            content
                .offset(
                    y: Self.chatScrollTransitionOffset(
                        phaseValue: phase.value,
                        configuredOffset: scrollAnimOffset,
                        isEnabled: scrollAnimEnabled,
                        isConnectedToAdjacentBubble: mergeWithPrevious || mergeWithNext,
                        isBottomPinnedStreamingBubble: isBottomPinnedStreamingBubble,
                        isViewportTransitioning: Self
                            .shouldSuppressScrollTransitionForViewportChange(
                                isLayoutSettling: layoutSettling,
                                keepsBottomPinned: keepsBottomPinned,
                                isUserInteracting: scrollUserInteracting
                            ),
                        isTimelineNavigationActive: timelineNavigationActive,
                        keepsBottomPinned: keepsBottomPinned,
                        isUserInteracting: scrollUserInteracting,
                        isSendFlightTarget: reportsSendFlightTarget
                    )
                )
        }

        if let contexts = outgoingContinuationContextsByMessageID[message.id] {
            ForEach(contexts) { context in
                outgoingContinuationLinkBubble(context)
            }
        }
    }
}
