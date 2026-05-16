// ============================================================================
// ChatBubble.swift
// ============================================================================
// ETOS LLM Studio
//
// 本视图作为聊天消息气泡的入口，负责组织气泡布局、附件入口、
// 工具详情入口与消息正文渲染流程。
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import AVFoundation
import Combine
import WebKit

struct ChatBubble: View {
    @ObservedObject var messageState: ChatMessageRenderState
    let preparedMarkdownPayload: ETPreparedMarkdownRenderPayload?
    let preparedReasoningMarkdownPayload: ETPreparedMarkdownRenderPayload?
    @Binding var isReasoningExpanded: Bool
    let isReasoningAutoPreview: Bool
    @Binding var isToolCallsExpanded: Bool
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let enableNoBubbleUI: Bool
    let enableAdvancedRenderer: Bool
    let enableExperimentalToolResultDisplay: Bool
    let enableMathRendering: Bool
    let showsStreamingIndicators: Bool
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    let connectsTimelineFromPrevious: Bool
    let connectsTimelineToNext: Bool
    let responseAttemptVersionInfo: ChatResponseAttemptVersionInfo?
    let hasAutoOpenedPendingToolCall: (String) -> Bool
    let markPendingToolCallAutoOpened: (String) -> Void
    let onSwitchToPreviousVersion: () -> Void
    let onSwitchToNextVersion: () -> Void
    let onOpenMore: (() -> Void)?
    
    @StateObject var audioPlayer = AudioPlayerManager()
    @State var imagePreview: ImagePreviewPayload?
    @State var selectedToolCallDetailSheetItem: ToolCallDetailSheetItem?
    @State var showRawToolResultInDetailSheet: Bool = false
    @ObservedObject var toolPermissionCenter = ToolPermissionCenter.shared
    @ObservedObject var appearanceProfileManager = ChatAppearanceProfileManager.shared
    @Environment(\.colorScheme) var colorScheme

    init(
        messageState: ChatMessageRenderState,
        preparedMarkdownPayload: ETPreparedMarkdownRenderPayload? = nil,
        preparedReasoningMarkdownPayload: ETPreparedMarkdownRenderPayload? = nil,
        isReasoningExpanded: Binding<Bool>,
        isReasoningAutoPreview: Bool = false,
        isToolCallsExpanded: Binding<Bool>,
        enableMarkdown: Bool,
        enableBackground: Bool,
        enableLiquidGlass: Bool,
        enableNoBubbleUI: Bool,
        enableAdvancedRenderer: Bool = false,
        enableExperimentalToolResultDisplay: Bool = true,
        enableMathRendering: Bool = false,
        showsStreamingIndicators: Bool,
        mergeWithPrevious: Bool,
        mergeWithNext: Bool,
        connectsTimelineFromPrevious: Bool = false,
        connectsTimelineToNext: Bool = false,
        responseAttemptVersionInfo: ChatResponseAttemptVersionInfo? = nil,
        hasAutoOpenedPendingToolCall: @escaping (String) -> Bool = { _ in false },
        markPendingToolCallAutoOpened: @escaping (String) -> Void = { _ in },
        onSwitchToPreviousVersion: @escaping () -> Void,
        onSwitchToNextVersion: @escaping () -> Void,
        onOpenMore: (() -> Void)? = nil
    ) {
        self.messageState = messageState
        self.preparedMarkdownPayload = preparedMarkdownPayload
        self.preparedReasoningMarkdownPayload = preparedReasoningMarkdownPayload
        self._isReasoningExpanded = isReasoningExpanded
        self.isReasoningAutoPreview = isReasoningAutoPreview
        self._isToolCallsExpanded = isToolCallsExpanded
        self.enableMarkdown = enableMarkdown
        self.enableBackground = enableBackground
        self.enableLiquidGlass = enableLiquidGlass
        self.enableNoBubbleUI = enableNoBubbleUI
        self.enableAdvancedRenderer = enableAdvancedRenderer
        self.enableExperimentalToolResultDisplay = enableExperimentalToolResultDisplay
        self.enableMathRendering = enableMathRendering
        self.showsStreamingIndicators = showsStreamingIndicators
        self.mergeWithPrevious = mergeWithPrevious
        self.mergeWithNext = mergeWithNext
        self.connectsTimelineFromPrevious = connectsTimelineFromPrevious
        self.connectsTimelineToNext = connectsTimelineToNext
        self.responseAttemptVersionInfo = responseAttemptVersionInfo
        self.hasAutoOpenedPendingToolCall = hasAutoOpenedPendingToolCall
        self.markPendingToolCallAutoOpened = markPendingToolCallAutoOpened
        self.onSwitchToPreviousVersion = onSwitchToPreviousVersion
        self.onSwitchToNextVersion = onSwitchToNextVersion
        self.onOpenMore = onOpenMore
    }
    
    var message: ChatMessage {
        messageState.visualMessage
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // 用户消息靠右；无气泡助手消息用左右 Spacer 居中阅读列。
            if isOutgoing || usesNoBubbleStyle {
                Spacer(minLength: rowSideSpacerMinLength)
            }
            
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                // 图片附件 - 作为气泡显示
                if !shouldPlaceImagesAfterText,
                   let imageFileNames = message.imageFileNames,
                   !imageFileNames.isEmpty {
                    imageAttachmentsView(fileNames: imageFileNames)
                }

                // 文件附件 - 作为气泡显示
                if let fileFileNames = message.fileFileNames, !fileFileNames.isEmpty {
                    fileAttachmentsView(fileNames: fileFileNames)
                }
                
                // 气泡内容（仅当有非图片内容时显示）
                if shouldShowTextBubble {
                    if shouldRenderToolCallsAsSeparateBubbles {
                        separatedToolCallBubbleStack
                    } else {
                        bubbleContainer {
                            textContentStack(includeToolCalls: true)
                        }
                    }
                }

                if shouldPlaceImagesAfterText,
                   let imageFileNames = message.imageFileNames,
                   !imageFileNames.isEmpty {
                    imageAttachmentsView(fileNames: imageFileNames)
                }

                if shouldShowVersionIndicator {
                    versionSwitcherRow
                }
            }
            .frame(width: usesNoBubbleStyle ? bubbleMaxWidth : nil, alignment: .leading)
            .frame(maxWidth: usesNoBubbleStyle ? nil : bubbleMaxWidth, alignment: isOutgoing ? .trailing : .leading)
            
            // AI 普通气泡靠左；无气泡助手消息保留对称右侧 Spacer。
            if !isOutgoing || usesNoBubbleStyle {
                Spacer(minLength: rowSideSpacerMinLength)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.top, mergeWithPrevious ? 0 : rowVerticalPadding)
        .padding(.bottom, mergeWithNext ? 0 : rowVerticalPadding)
        .modifier(ChatBubbleOpenMoreGestureModifier(onOpenMore: onOpenMore))
        .sheet(item: $imagePreview) { payload in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: payload.image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            }
        }
        .sheet(item: $selectedToolCallDetailSheetItem) { item in
            toolCallDetailSheet(for: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            autoPresentPendingToolCallIfNeeded()
        }
        .onChange(of: toolPermissionCenter.activeRequest?.id) { _, _ in
            autoPresentPendingToolCallIfNeeded()
        }
        .onChange(of: toolCallAutoPresentationSignature) { _, _ in
            autoPresentPendingToolCallIfNeeded()
        }
    }
}
