// ============================================================================
// ChatBubble.swift
// ============================================================================
// 聊天气泡 (Telegram 风格)
// - 仿 Telegram 气泡形状与配色
// - 用户消息：蓝色
// - AI 消息：白色/灰色
// - 支持 Markdown 与推理展开
// - 支持语音消息播放
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import AVFoundation
import Combine
import WebKit

// MARK: - Telegram 风格气泡形状

/// Telegram 风格的气泡形状（无尾巴）
struct TelegramBubbleShape: Shape {
    let isOutgoing: Bool  // 是否是发出的消息（用户消息）
    let cornerRadius: CGFloat
    
    init(isOutgoing: Bool, cornerRadius: CGFloat = 18) {
        self.isOutgoing = isOutgoing
        self.cornerRadius = cornerRadius
    }
    
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect)
    }
}

private struct BubbleCornerShape: Shape {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomLeft: CGFloat
    let bottomRight: CGFloat

    func path(in rect: CGRect) -> Path {
        let tl = min(min(topLeft, rect.width / 2), rect.height / 2)
        let tr = min(min(topRight, rect.width / 2), rect.height / 2)
        let bl = min(min(bottomLeft, rect.width / 2), rect.height / 2)
        let br = min(min(bottomRight, rect.width / 2), rect.height / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            radius: tr,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
            radius: bl,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(
            center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
            radius: tl,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

struct ChatBubble: View {
    @ObservedObject var messageState: ChatMessageRenderState
    let preparedMarkdownPayload: ETPreparedMarkdownRenderPayload?
    @Binding var isReasoningExpanded: Bool
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
    let hasAutoOpenedPendingToolCall: (String) -> Bool
    let markPendingToolCallAutoOpened: (String) -> Void
    let onSwitchToPreviousVersion: () -> Void
    let onSwitchToNextVersion: () -> Void
    
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var imagePreview: ImagePreviewPayload?
    @State private var availableWidth: CGFloat = 0
    @State private var selectedToolCallDetailSheetItem: ToolCallDetailSheetItem?
    @State private var showRawToolResultInDetailSheet: Bool = false
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("enableCustomUserBubbleColor") private var enableCustomUserBubbleColor: Bool = false
    @AppStorage("customUserBubbleColorHex") private var customUserBubbleColorHex: String = "3D8FF2FF"
    @AppStorage("enableCustomAssistantBubbleColor") private var enableCustomAssistantBubbleColor: Bool = false
    @AppStorage("customAssistantBubbleColorHex") private var customAssistantBubbleColorHex: String = "F2F2F7FF"
    @AppStorage("enableCustomLightTextColor") private var enableCustomLightTextColor: Bool = false
    @AppStorage("customLightTextColorHex") private var customLightTextColorHex: String = "1C1C1EFF"
    @AppStorage("enableCustomDarkTextColor") private var enableCustomDarkTextColor: Bool = false
    @AppStorage("customDarkTextColorHex") private var customDarkTextColorHex: String = "FFFFFFFF"

    init(
        messageState: ChatMessageRenderState,
        preparedMarkdownPayload: ETPreparedMarkdownRenderPayload? = nil,
        isReasoningExpanded: Binding<Bool>,
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
        hasAutoOpenedPendingToolCall: @escaping (String) -> Bool = { _ in false },
        markPendingToolCallAutoOpened: @escaping (String) -> Void = { _ in },
        onSwitchToPreviousVersion: @escaping () -> Void,
        onSwitchToNextVersion: @escaping () -> Void
    ) {
        self.messageState = messageState
        self.preparedMarkdownPayload = preparedMarkdownPayload
        self._isReasoningExpanded = isReasoningExpanded
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
        self.hasAutoOpenedPendingToolCall = hasAutoOpenedPendingToolCall
        self.markPendingToolCallAutoOpened = markPendingToolCallAutoOpened
        self.onSwitchToPreviousVersion = onSwitchToPreviousVersion
        self.onSwitchToNextVersion = onSwitchToNextVersion
    }
    
    private var message: ChatMessage {
        messageState.message
    }

    // Telegram 颜色
    private let telegramBlue = Color(red: 0.24, green: 0.56, blue: 0.95)
    private let telegramBlueDark = Color(red: 0.17, green: 0.45, blue: 0.82)

    private var resolvedUserBubbleStartColor: Color {
        guard enableCustomUserBubbleColor else { return telegramBlue }
        return ChatAppearanceColorCodec.color(from: customUserBubbleColorHex, fallback: telegramBlue)
    }

    private var resolvedUserBubbleEndColor: Color {
        guard enableCustomUserBubbleColor else { return telegramBlueDark }
        return ChatAppearanceColorCodec.darkened(resolvedUserBubbleStartColor, factor: 0.86)
    }

    private var resolvedAssistantBubbleColor: Color? {
        guard enableCustomAssistantBubbleColor else { return nil }
        return ChatAppearanceColorCodec.color(
            from: customAssistantBubbleColorHex,
            fallback: Color(uiColor: .secondarySystemBackground)
        )
    }

    private var customTextColorOverride: Color? {
        if colorScheme == .dark {
            guard enableCustomDarkTextColor else { return nil }
            return ChatAppearanceColorCodec.color(from: customDarkTextColorHex, fallback: .white)
        }
        guard enableCustomLightTextColor else { return nil }
        return ChatAppearanceColorCodec.color(from: customLightTextColorHex, fallback: .primary)
    }
    
    private var isOutgoing: Bool {
        message.role == .user
    }
    
    private var isError: Bool {
        message.role == .error || (message.role == .assistant && message.content.hasPrefix("重试失败"))
    }

    private var usesNoBubbleStyle: Bool {
        enableNoBubbleUI && !isOutgoing && !isError
    }

    private var bubbleShape: BubbleCornerShape {
        let baseRadius: CGFloat = 18
        let mergedRadius: CGFloat = 0
        let topRadius = mergeWithPrevious ? mergedRadius : baseRadius
        let bottomRadius = mergeWithNext ? mergedRadius : baseRadius
        return BubbleCornerShape(
            topLeft: topRadius,
            topRight: topRadius,
            bottomLeft: bottomRadius,
            bottomRight: bottomRadius
        )
    }

    private var shouldShowMergedSeparator: Bool {
        !usesNoBubbleStyle && mergeWithPrevious && !isOutgoing
    }

    private var separatorThickness: CGFloat {
        1 / UIScreen.main.scale
    }

    private var separatorColor: Color {
        if isOutgoing {
            return Color.white.opacity(0.2)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var bubbleShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        if usesNoBubbleStyle {
            return (Color.clear, 0, 0)
        }
        if mergeWithPrevious && mergeWithNext {
            return (Color.black.opacity(0.04), 1, 0)
        }
        return (Color.black.opacity(0.08), 3, 1)
    }

    private var bubbleMaxWidth: CGFloat {
        let baseWidth = availableWidth > 0 ? availableWidth : UIScreen.main.bounds.width
        let rowChromeWidth = rowHorizontalPadding * 2 + (usesNoBubbleStyle ? 0 : rowSideSpacerMinLength)
        let availableBubbleWidth = max(1, baseWidth - rowChromeWidth)
        let widthRatio: CGFloat
        if usesNoBubbleStyle {
            widthRatio = 0.92
        } else if isOutgoing {
            widthRatio = 0.88
        } else {
            widthRatio = 0.94
        }
        return min(baseWidth * widthRatio, availableBubbleWidth)
    }

    private var shouldForceMergedWidth: Bool {
        if usesNoBubbleStyle {
            return true
        }
        return !isOutgoing && (mergeWithPrevious || mergeWithNext)
    }

    private var rowSideSpacerMinLength: CGFloat {
        usesNoBubbleStyle ? 0 : 20
    }

    private var rowHorizontalPadding: CGFloat {
        8
    }

    private var rowVerticalPadding: CGFloat {
        let basePadding: CGFloat = 3
        return enableNoBubbleUI ? basePadding * 3 : basePadding
    }

    private var textForegroundColor: Color {
        if isError && usesNoBubbleStyle {
            return .red
        }
        if usesNoBubbleStyle {
            return resolvedTextColor(default: .primary)
        }
        return resolvedTextColor(default: isOutgoing ? .white : .primary)
    }

    private func resolvedTextColor(default defaultColor: Color) -> Color {
        customTextColorOverride ?? defaultColor
    }

    private func resolvedSecondaryTextColor(default defaultColor: Color, customOpacity: Double = 0.78) -> Color {
        if let customTextColorOverride {
            return customTextColorOverride.opacity(customOpacity)
        }
        return defaultColor
    }
    
    /// 图片占位符文本（各语言版本）
    private static let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]
    
    /// 判断消息是否只有图片（没有实际文字内容）
    private var hasOnlyImages: Bool {
        guard let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty else {
            return false
        }
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholderOnly = trimmedContent.isEmpty || Self.imagePlaceholders.contains(trimmedContent)
        return isPlaceholderOnly && message.reasoningContent == nil && message.toolCalls == nil && message.audioFileName == nil
    }
    
    private var hasToolCalls: Bool {
        !(message.toolCalls ?? []).isEmpty
    }
    
    private var hasToolResults: Bool {
        let hasWidgetPayload = message.toolCalls?.contains { call in
            ToolWidgetPayloadParser.parse(from: call.arguments) != nil
        } ?? false
        let hasCallResults = message.toolCalls?.contains { call in
            !(call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        if message.role == .tool {
            let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasCallResults || hasContent || hasWidgetPayload
        }
        return hasCallResults || hasWidgetPayload
    }

    private func isShowWidgetToolCall(_ call: InternalToolCall) -> Bool {
        call.toolName == AppToolKind.showWidget.toolName
    }

    private func showWidgetPayload(for call: InternalToolCall) -> ToolWidgetPayload? {
        guard isShowWidgetToolCall(call) else { return nil }

        if let payload = ToolWidgetPayloadParser.parse(from: call.arguments) {
            return payload
        }

        let resolved = resolvedToolResultText(for: call)
        if let payload = ToolWidgetPayloadParser.parse(from: resolved) {
            return payload
        }

        if message.role == .tool,
           let payload = ToolWidgetPayloadParser.parse(from: message.content) {
            return payload
        }

        return nil
    }

    private var standaloneShowWidgetPayload: ToolWidgetPayload? {
        guard message.role == .tool,
              (message.toolCalls?.isEmpty ?? true) else {
            return nil
        }
        return ToolWidgetPayloadParser.parse(from: message.content)
    }

    private var hasPendingToolResults: Bool {
        guard message.role != .tool else { return false }
        guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return false }
        guard !hasToolResults else { return false }
        return activeToolPermissionRequest == nil
    }

    private var shouldShimmerReasoningHeader: Bool {
        guard showsStreamingIndicators, message.role == .assistant else { return false }
        return true
    }

    private var reasoningStartedAt: Date? {
        message.responseMetrics?.reasoningStartedAt
    }

    private var reasoningCompletedAt: Date? {
        message.responseMetrics?.reasoningCompletedAt
    }

    private var resolvedToolCallsPlacement: ToolCallsPlacement {
        if let placement = message.toolCallsPlacement {
            return placement
        }
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedContent.isEmpty ? .afterReasoning : .afterContent
    }

    private var shouldShowToolCallsBeforeContent: Bool {
        hasToolCalls && resolvedToolCallsPlacement == .afterReasoning
    }

    private var shouldShowToolCallsAfterContent: Bool {
        hasToolCalls && resolvedToolCallsPlacement == .afterContent
    }

    private var shouldRenderToolCallsAsSeparateBubbles: Bool {
        // 工具调用已并入同一个助手气泡的时间线，保留旧分支以降低本次改动范围。
        false
    }

    private var shouldRenderReasoningToolTimeline: Bool {
        !isOutgoing
            && !isError
            && (hasToolCalls || !(message.reasoningContent ?? "").isEmpty)
    }

    private var hasMainContentWhenToolCallsSeparated: Bool {
        if hasOnlyImages {
            return false
        }
        let hasReasoning = !(message.reasoningContent ?? "").isEmpty
        let hasVisibleContent = !message.content.isEmpty && message.role != .tool
        return hasReasoning || hasVisibleContent
    }
    
    private var activeToolPermissionRequest: ToolPermissionRequest? {
        guard let toolCalls = message.toolCalls else { return nil }
        return toolCalls.compactMap(activeToolPermissionRequest(for:)).first
    }

    private var pendingToolCallForAutoPresentation: InternalToolCall? {
        guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return nil }
        return toolCalls.first { call in
            activeToolPermissionRequest(for: call) != nil && !hasAutoOpenedPendingToolCall(call.id)
        }
    }

    private var shouldShowTextBubble: Bool {
        if hasOnlyImages {
            return false
        }
        let hasReasoning = !(message.reasoningContent ?? "").isEmpty
        let hasContent = !message.content.isEmpty
        let shouldShowThinking = message.role == .assistant
            && !hasContent
            && !hasReasoning
            && !hasToolCalls

        switch message.role {
        case .tool:
            return hasToolCalls || hasContent
        case .assistant, .system:
            return hasToolCalls || hasReasoning || hasContent || shouldShowThinking
        case .user, .error:
            return hasContent || hasReasoning || hasToolCalls
        @unknown default:
            return hasReasoning || hasContent
        }
    }

    private var shouldPlaceImagesAfterText: Bool {
        !isOutgoing && shouldShowTextBubble
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
                            
                            // 版本指示器（Telegram 风格：右下角）
                            if message.hasMultipleVersions {
                                HStack(spacing: 6) {
                                    compactVersionIndicator
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }

                if shouldPlaceImagesAfterText,
                   let imageFileNames = message.imageFileNames,
                   !imageFileNames.isEmpty {
                    imageAttachmentsView(fileNames: imageFileNames)
                }
            }
            .frame(width: usesNoBubbleStyle ? bubbleMaxWidth : nil, alignment: .leading)
            .frame(maxWidth: usesNoBubbleStyle ? nil : bubbleMaxWidth, alignment: isOutgoing ? .trailing : .leading)
            
            // AI 普通气泡靠左；无气泡助手消息保留对称右侧 Spacer。
            if !isOutgoing || usesNoBubbleStyle {
                Spacer(minLength: rowSideSpacerMinLength)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.top, mergeWithPrevious ? 0 : rowVerticalPadding)
        .padding(.bottom, mergeWithNext ? 0 : rowVerticalPadding)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RowWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(RowWidthKey.self) { newValue in
            if availableWidth != newValue {
                availableWidth = newValue
            }
        }
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

    private struct RowWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private struct ToolCallDetailSheetItem: Identifiable, Equatable {
        let messageID: UUID
        let toolCallID: String
        let fallbackToolCall: InternalToolCall

        var id: String {
            "\(messageID.uuidString)-\(toolCallID)"
        }
    }

    private enum ToolCallBubbleStatus: Equatable {
        case pendingApproval
        case running
        case finished
        case rejected

        var title: String {
            switch self {
            case .pendingApproval:
                return "等待审批"
            case .running:
                return "执行中"
            case .finished:
                return "已完成"
            case .rejected:
                return "已拒绝"
            }
        }

        var iconName: String {
            switch self {
            case .pendingApproval:
                return "hourglass"
            case .running:
                return "clock.arrow.trianglehead.counterclockwise.rotate.90"
            case .finished:
                return "checkmark.circle.fill"
            case .rejected:
                return "xmark.circle.fill"
            }
        }

        var accentColor: Color {
            switch self {
            case .pendingApproval:
                return .orange
            case .running:
                return .blue
            case .finished:
                return .green
            case .rejected:
                return .red
            }
        }
    }
    
    // MARK: - 紧凑版本指示器 (Telegram 风格)
    
    @ViewBuilder
    private var compactVersionIndicator: some View {
        HStack(spacing: 4) {
            Button {
                onSwitchToPreviousVersion()
            } label: {
                Image(systemName: "chevron.left")
                    .etFont(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(message.getCurrentVersionIndex() == 0)
            .opacity(message.getCurrentVersionIndex() > 0 ? 1 : 0.4)
            
            Text("\(message.getCurrentVersionIndex() + 1)/\(message.getAllVersions().count)")
                .etFont(.system(size: 14, weight: .semibold))
                .monospacedDigit()
            
            Button {
                onSwitchToNextVersion()
            } label: {
                Image(systemName: "chevron.right")
                    .etFont(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(message.getCurrentVersionIndex() >= message.getAllVersions().count - 1)
            .opacity(message.getCurrentVersionIndex() < message.getAllVersions().count - 1 ? 1 : 0.4)
        }
        .foregroundStyle(
            usesNoBubbleStyle
                ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8)
                : (isOutgoing
                    ? resolvedSecondaryTextColor(default: Color.white.opacity(0.8), customOpacity: 0.8)
                    : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8))
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(
                    usesNoBubbleStyle
                        ? Color.clear
                        : (isOutgoing
                            ? resolvedSecondaryTextColor(default: Color.white, customOpacity: 0.2)
                            : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.15))
                )
        )
    }
    
    // MARK: - 气泡渐变背景
    
    private var bubbleGradient: some ShapeStyle {
        if usesNoBubbleStyle {
            return AnyShapeStyle(Color.clear)
        }
        let userOpacity = enableBackground ? 0.85 : 1.0
        let assistantOpacity = enableBackground ? 0.75 : 1.0
        let errorOpacity = enableBackground ? 0.8 : 1.0

        if isError {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.red.opacity(0.85 * errorOpacity), Color.red.opacity(0.7 * errorOpacity)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        
        switch message.role {
        case .user:
            // Telegram 蓝色渐变
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        resolvedUserBubbleStartColor.opacity(userOpacity),
                        resolvedUserBubbleEndColor.opacity(userOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .assistant, .system, .tool:
            // 接收消息：浅灰/白色
            let baseColor: Color
            if let resolvedAssistantBubbleColor {
                baseColor = resolvedAssistantBubbleColor.opacity(enableBackground ? assistantOpacity : 1)
            } else {
                baseColor = enableBackground
                    ? Color(uiColor: .secondarySystemBackground).opacity(assistantOpacity)
                    : Color(uiColor: .systemBackground)
            }
            return AnyShapeStyle(baseColor)
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.15 * errorOpacity))
        @unknown default:
            return AnyShapeStyle(Color(UIColor.secondarySystemBackground))
        }
    }

    private var standaloneBubbleShape: BubbleCornerShape {
        BubbleCornerShape(
            topLeft: 18,
            topRight: 18,
            bottomLeft: 18,
            bottomRight: 18
        )
    }

    private func connectedAssistantBubbleShape(isFirst: Bool, isLast: Bool) -> BubbleCornerShape {
        let baseRadius: CGFloat = 18
        let mergedRadius: CGFloat = 0
        let topRadius = isFirst ? (mergeWithPrevious ? mergedRadius : baseRadius) : mergedRadius
        let bottomRadius = isLast ? (mergeWithNext ? mergedRadius : baseRadius) : mergedRadius
        return BubbleCornerShape(
            topLeft: topRadius,
            topRight: topRadius,
            bottomLeft: bottomRadius,
            bottomRight: bottomRadius
        )
    }

    @ViewBuilder
    private func bubbleBackground(for shape: BubbleCornerShape) -> some View {
        if usesNoBubbleStyle {
            shape
                .fill(Color.clear)
        } else if enableLiquidGlass {
            if #available(iOS 26.0, *) {
                shape
                    .fill(bubbleGradient)
                    .glassEffect(.clear, in: shape)
                    .clipShape(shape)
            } else {
                shape
                    .fill(bubbleGradient)
            }
        } else {
            shape
                .fill(bubbleGradient)
        }
    }

    private func bubbleDecoratedBackground(shape: BubbleCornerShape, showMergedSeparator: Bool) -> some View {
        return ZStack(alignment: .top) {
            bubbleBackground(for: shape)
            if showMergedSeparator {
                Rectangle()
                    .fill(separatorColor)
                    .frame(height: separatorThickness)
            }
        }
        .clipShape(shape)
    }

    @ViewBuilder
    private func bubbleContainerCore<Content: View>(
        shape: BubbleCornerShape,
        showMergedSeparator: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.horizontal, usesNoBubbleStyle ? 2 : 12)
        .padding(.vertical, usesNoBubbleStyle ? 4 : 8)
        .frame(width: shouldForceMergedWidth ? bubbleMaxWidth : nil, alignment: isOutgoing ? .trailing : .leading)
        .background(
            bubbleDecoratedBackground(
                shape: shape,
                showMergedSeparator: showMergedSeparator
            )
        )
        .shadow(color: bubbleShadow.color, radius: bubbleShadow.radius, y: bubbleShadow.y)
    }

    @ViewBuilder
    private func bubbleContainer<Content: View>(
        standalone: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = standalone ? standaloneBubbleShape : bubbleShape
        bubbleContainerCore(
            shape: shape,
            showMergedSeparator: !standalone && shouldShowMergedSeparator,
            content: content
        )
    }

    @ViewBuilder
    private func connectedToolBubbleContainer<Content: View>(
        isFirst: Bool,
        isLast: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        bubbleContainerCore(
            shape: connectedAssistantBubbleShape(isFirst: isFirst, isLast: isLast),
            showMergedSeparator: isFirst && shouldShowMergedSeparator,
            content: content
        )
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var separatedToolCallBubbleStack: some View {
        let toolCalls = message.toolCalls ?? []
        let hasMainBubble = hasMainContentWhenToolCallsSeparated
        let totalBubbleCount = toolCalls.count + (hasMainBubble ? 1 : 0)

        VStack(alignment: .leading, spacing: 0) {
            if hasMainBubble {
                connectedToolBubbleContainer(isFirst: true, isLast: totalBubbleCount == 1) {
                    textContentStack(includeToolCalls: false)

                    if message.hasMultipleVersions {
                        HStack(spacing: 6) {
                            compactVersionIndicator
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

            ForEach(Array(toolCalls.enumerated()), id: \.element.id) { offset, call in
                let position = (hasMainBubble ? 1 : 0) + offset
                let isFirst = position == 0
                let isLast = position == (totalBubbleCount - 1)

                connectedToolBubbleContainer(isFirst: isFirst, isLast: isLast) {
                    toolCallBubbleContent(for: call)
                }
            }
        }
    }

    @ViewBuilder
    private func textContentStack(includeToolCalls: Bool) -> some View {
        let toolCalls = message.toolCalls ?? []
        let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canUseTimeline = shouldRenderReasoningToolTimeline && includeToolCalls

        if canUseTimeline {
            if let reasoning, !reasoning.isEmpty {
                reasoningToolTimeline(
                    reasoning: reasoning,
                    toolCalls: shouldShowToolCallsBeforeContent ? toolCalls : []
                )
            } else if shouldShowToolCallsBeforeContent {
                reasoningToolTimeline(reasoning: nil, toolCalls: toolCalls)
            }
        } else {
            // 思考过程 (Telegram 风格折叠)
            if let reasoning,
               !reasoning.isEmpty {
                ReasoningDisclosureView(
                    reasoning: reasoning,
                    isExpanded: $isReasoningExpanded,
                    isOutgoing: isOutgoing,
                    usesNoBubbleStyle: usesNoBubbleStyle,
                    isShimmering: shouldShimmerReasoningHeader,
                    customTextColor: customTextColorOverride,
                    reasoningStartedAt: reasoningStartedAt,
                    reasoningCompletedAt: reasoningCompletedAt,
                    reasoningSummary: message.responseMetrics?.reasoningSummary
                )
            }

            if includeToolCalls && shouldShowToolCallsBeforeContent {
                toolCallsSection
            }
        }
        
        // 消息正文
        if let standaloneShowWidgetPayload {
            ToolWidgetRendererCard(payload: standaloneShowWidgetPayload)
        } else if !message.content.isEmpty, message.role != .tool || (message.toolCalls?.isEmpty ?? true) {
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName)
            } else {
                renderContent(message.content)
                    .etFont(.body)
                    .foregroundStyle(textForegroundColor)
                    .textSelection(.enabled)
            }
        } else if message.role == .assistant,
                  (message.reasoningContent ?? "").isEmpty,
                  (message.toolCalls ?? []).isEmpty {
            // 加载指示器
            if showsStreamingIndicators {
                ShimmeringText(
                    text: "正在思考...",
                    font: .subheadline,
                    baseColor: resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75),
                    highlightColor: resolvedTextColor(default: Color.primary.opacity(0.85))
                )
            } else {
                Text("正在思考...")
                    .etFont(.subheadline)
                    .foregroundStyle(resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75))
            }
        }

        if canUseTimeline {
            if shouldShowToolCallsAfterContent {
                reasoningToolTimeline(reasoning: nil, toolCalls: toolCalls)
            }
        } else if includeToolCalls && shouldShowToolCallsAfterContent {
            toolCallsSection
        }
    }

    @ViewBuilder
    private func reasoningToolTimeline(reasoning: String?, toolCalls: [InternalToolCall]) -> some View {
        let trimmedReasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasReasoning = !(trimmedReasoning ?? "").isEmpty
        let toolPresentations = timelineToolCallPresentations(for: toolCalls, hasReasoning: hasReasoning)
        let stepCount = (hasReasoning ? 1 : 0) + toolPresentations.filter { $0.stepIndex != nil }.count

        if stepCount > 0 || !toolPresentations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let trimmedReasoning, hasReasoning {
                    AssistantTimelineStepShell(
                        iconName: "lightbulb",
                        iconColor: timelineAccentColor,
                        lineColor: timelineLineColor,
                        isFirst: true,
                        isLast: stepCount == 1
                    ) {
                        TimelineReasoningStepView(
                            reasoning: trimmedReasoning,
                            isExpanded: $isReasoningExpanded,
                            isShimmering: shouldShimmerReasoningHeader,
                            customTextColor: customTextColorOverride,
                            usesNoBubbleStyle: usesNoBubbleStyle,
                            reasoningStartedAt: reasoningStartedAt,
                            reasoningCompletedAt: reasoningCompletedAt,
                            reasoningSummary: message.responseMetrics?.reasoningSummary
                        )
                    }
                }

                ForEach(toolPresentations) { presentation in
                    if let payload = presentation.widgetPayload {
                        timelineWidgetContent(payload: payload)
                    } else if let stepIndex = presentation.stepIndex {
                        let status = toolCallStatus(for: presentation.call)
                        AssistantTimelineStepShell(
                            iconName: "wrench.and.screwdriver",
                            iconColor: status.accentColor,
                            lineColor: timelineLineColor,
                            isFirst: stepIndex == 0,
                            isLast: stepIndex == stepCount - 1
                        ) {
                            timelineToolCallRow(for: presentation.call, status: status)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private struct TimelineToolCallPresentation: Identifiable {
        let call: InternalToolCall
        let widgetPayload: ToolWidgetPayload?
        let stepIndex: Int?

        var id: String {
            call.id
        }
    }

    private func timelineToolCallPresentations(
        for toolCalls: [InternalToolCall],
        hasReasoning: Bool
    ) -> [TimelineToolCallPresentation] {
        var nextStepIndex = hasReasoning ? 1 : 0
        return toolCalls.map { call in
            if let payload = showWidgetPayload(for: call) {
                return TimelineToolCallPresentation(call: call, widgetPayload: payload, stepIndex: nil)
            }
            let stepIndex = nextStepIndex
            nextStepIndex += 1
            return TimelineToolCallPresentation(call: call, widgetPayload: nil, stepIndex: stepIndex)
        }
    }

    private var timelineAccentColor: Color {
        customTextColorOverride?.opacity(0.9) ?? (usesNoBubbleStyle ? Color.primary.opacity(0.82) : Color.secondary)
    }

    private var timelineLineColor: Color {
        customTextColorOverride?.opacity(0.28) ?? Color.secondary.opacity(0.34)
    }

    @ViewBuilder
    private func timelineToolCallRow(for call: InternalToolCall, status: ToolCallBubbleStatus) -> some View {
        let label = toolDisplayLabel(for: call.toolName)
        Button {
            showRawToolResultInDetailSheet = false
            selectedToolCallDetailSheetItem = ToolCallDetailSheetItem(
                messageID: message.id,
                toolCallID: call.id,
                fallbackToolCall: call
            )
        } label: {
            TimelineToolCallStepContent(
                label: label,
                statusTitle: status.title,
                statusIconName: status.iconName,
                statusColor: status.accentColor,
                summary: toolCallTimelineSummary(for: call),
                showPendingGuidance: shouldShowPendingGuidance(for: call),
                customTextColor: customTextColorOverride
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func timelineWidgetContent(payload: ToolWidgetPayload) -> some View {
        // show_widget 必须保持整列宽度，不能放进时间线 step，否则左侧连线会压缩 HTML 卡片。
        ToolWidgetRendererCard(payload: payload)
            .padding(.vertical, 4)
    }

    private func toolCallTimelineSummary(for call: InternalToolCall) -> String? {
        let result = resolvedToolResultText(for: call)
        if !result.isEmpty {
            return MCPToolResultFormatter.displayModel(from: result).summaryText
        }

        let argumentText = prettyPrintedJSONOrRaw(call.arguments)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard argumentText != "{}", !argumentText.isEmpty else {
            return nil
        }
        return String(argumentText.prefix(96))
    }

    @ViewBuilder
    private var toolCallsSection: some View {
        if let toolCalls = message.toolCalls,
           !toolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(toolCalls, id: \.id) { call in
                    toolCallBubbleContent(for: call)
                }
            }
        }
    }

    @ViewBuilder
    private func toolCallBubbleContent(for call: InternalToolCall) -> some View {
        if let payload = showWidgetPayload(for: call) {
            ToolWidgetRendererCard(payload: payload)
        } else {
            toolCallSummaryRow(for: call)
        }
    }

    private func resolvedToolResultText(for call: InternalToolCall) -> String {
        let fallback = message.role == .tool ? message.content : ""
        return (call.result ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isPendingToolResult(for call: InternalToolCall) -> Bool {
        if showWidgetPayload(for: call) != nil {
            return false
        }
        return hasPendingToolResults && resolvedToolResultText(for: call).isEmpty
    }

    private func shouldShowToolResult(for call: InternalToolCall) -> Bool {
        if showWidgetPayload(for: call) != nil {
            return false
        }
        return !resolvedToolResultText(for: call).isEmpty || isPendingToolResult(for: call)
    }

    private func activeToolPermissionRequest(for call: InternalToolCall) -> ToolPermissionRequest? {
        guard message.role != .user,
              let request = toolPermissionCenter.activeRequest else {
            return nil
        }
        let trimmedArgs = request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let callArgs = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMatch = call.toolName == request.toolName && callArgs == trimmedArgs
        return isMatch ? request : nil
    }

    private var toolCallAutoPresentationSignature: String {
        let callIDs = (message.toolCalls ?? []).map(\.id).joined(separator: "|")
        let activeRequestID = toolPermissionCenter.activeRequest?.id.uuidString ?? ""
        return "\(message.id.uuidString)#\(callIDs)#\(activeRequestID)"
    }

    private func autoPresentPendingToolCallIfNeeded() {
        guard selectedToolCallDetailSheetItem == nil else { return }
        guard let pendingCall = pendingToolCallForAutoPresentation else { return }
        markPendingToolCallAutoOpened(pendingCall.id)
        showRawToolResultInDetailSheet = false
        selectedToolCallDetailSheetItem = ToolCallDetailSheetItem(
            messageID: message.id,
            toolCallID: pendingCall.id,
            fallbackToolCall: pendingCall
        )
    }

    private func resolvedToolCall(for item: ToolCallDetailSheetItem) -> InternalToolCall {
        message.toolCalls?.first(where: { $0.id == item.toolCallID }) ?? item.fallbackToolCall
    }

    private func toolDisplayLabel(for toolName: String) -> String {
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        if let label = MCPManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = ShortcutToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = SkillManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = AppToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        return toolName
    }

    private func toolCallStatus(for call: InternalToolCall) -> ToolCallBubbleStatus {
        if activeToolPermissionRequest(for: call) != nil {
            return .pendingApproval
        }
        let resolvedResult = resolvedToolResultText(for: call)
        if resolvedResult.isEmpty {
            return .running
        }
        if isDeniedToolResultText(resolvedResult) {
            return .rejected
        }
        return .finished
    }

    private func isDeniedToolResultText(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("denied")
            || normalized.contains("拒绝")
            || normalized.contains("拒絕")
            || normalized.contains("rejected")
    }

    private func shouldShowPendingGuidance(for call: InternalToolCall) -> Bool {
        activeToolPermissionRequest(for: call) != nil
    }

    @ViewBuilder
    private func toolCallSummaryRow(for call: InternalToolCall) -> some View {
        let label = toolDisplayLabel(for: call.toolName)
        let status = toolCallStatus(for: call)
        Button {
            showRawToolResultInDetailSheet = false
            selectedToolCallDetailSheetItem = ToolCallDetailSheetItem(
                messageID: message.id,
                toolCallID: call.id,
                fallbackToolCall: call
            )
        } label: {
            ToolCallSummaryBubbleRow(
                label: label,
                statusTitle: status.title,
                statusIconName: status.iconName,
                statusColor: status.accentColor,
                showPendingGuidance: shouldShowPendingGuidance(for: call),
                isOutgoing: isOutgoing,
                customTextColor: customTextColorOverride
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toolCallDetailSheet(for item: ToolCallDetailSheetItem) -> some View {
        let call = resolvedToolCall(for: item)
        let displayName = toolDisplayLabel(for: call.toolName)
        let status = toolCallStatus(for: call)
        let argumentText = prettyPrintedJSONOrRaw(call.arguments)
        let resultText = resolvedToolResultText(for: call)
        let displayModel = MCPToolResultFormatter.displayModel(from: resultText)
        let permissionRequest = activeToolPermissionRequest(for: call)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(status.accentColor)
                        .etFont(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .etFont(.headline)
                        Text(status.title)
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("关闭") {
                        selectedToolCallDetailSheetItem = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                toolDetailSection(title: "工具参数") {
                    CappedScrollableText(
                        text: argumentText,
                        maxHeight: 240,
                        font: .system(.caption, design: .monospaced),
                        foreground: .secondary,
                        enableSelection: true
                    )
                }

                if permissionRequest == nil {
                    toolDetailSection(title: "工具结果") {
                        if resultText.isEmpty {
                            Text(status == .pendingApproval ? "等待你的审批后继续执行。" : "暂无返回结果。")
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        } else if enableExperimentalToolResultDisplay {
                            let primaryContent = displayModel.primaryContentText?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let hasPrimaryContent = !(primaryContent ?? "").isEmpty
                            let canToggleRaw = hasPrimaryContent && displayModel.shouldShowRawSection
                            let showRaw = canToggleRaw && showRawToolResultInDetailSheet

                            if showRaw || !hasPrimaryContent {
                                CappedScrollableText(
                                    text: displayModel.rawDisplayText,
                                    maxHeight: 240,
                                    font: .system(.caption, design: .monospaced),
                                    foreground: .secondary,
                                    enableSelection: true
                                )
                            } else if let primaryContent {
                                CappedScrollableText(
                                    text: primaryContent,
                                    maxHeight: 240,
                                    font: .footnote,
                                    foreground: .secondary,
                                    enableSelection: true
                                )
                            }

                            if canToggleRaw {
                                Divider()
                                HStack {
                                    Button(showRawToolResultInDetailSheet ? "显示整理结果" : "显示原文") {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            showRawToolResultInDetailSheet.toggle()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Spacer(minLength: 0)
                                }
                            }
                        } else {
                            CappedScrollableText(
                                text: resultText,
                                maxHeight: 240,
                                font: .system(.caption, design: .monospaced),
                                foreground: .secondary,
                                enableSelection: true
                            )
                        }
                    }
                }

                if let permissionRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("审批操作")
                            .etFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ToolPermissionInlineView(
                            request: permissionRequest,
                            onDecision: { decision in
                                toolPermissionCenter.resolveActiveRequest(with: decision)
                                selectedToolCallDetailSheetItem = nil
                            }
                        )
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func toolDetailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func prettyPrintedJSONOrRaw(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let prettyText = String(data: prettyData, encoding: .utf8) else {
            return trimmed
        }
        return prettyText
    }
    
    @ViewBuilder
    private func imageAttachmentsView(fileNames: [String]) -> some View {
        HStack(spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 0)
            }
            
            // 根据图片数量决定布局
            let columns: [GridItem] = fileNames.count == 1
                ? [GridItem(.flexible(minimum: 150, maximum: 220))]
                : [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 4)]
            let minWidth = fileNames.count == 1 ? 150.0 : 80.0
            let maxWidth = fileNames.count == 1 ? 220.0 : 140.0
            let itemHeight = fileNames.count == 1 ? 180.0 : 100.0
            
            LazyVGrid(columns: columns, alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                ForEach(fileNames, id: \.self) { fileName in
                    AttachmentImageView(
                        fileName: fileName,
                        minWidth: minWidth,
                        maxWidth: maxWidth,
                        height: itemHeight,
                        cornerRadius: 16
                    ) { image in
                        imagePreview = ImagePreviewPayload(image: image)
                    }
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.65, alignment: isOutgoing ? .trailing : .leading)
            
            if !isOutgoing {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func fileAttachmentsView(fileNames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fileNames, id: \.self) { fileName in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .etFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            usesNoBubbleStyle
                                ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8)
                                : (isOutgoing
                                    ? resolvedSecondaryTextColor(default: Color.white.opacity(0.85), customOpacity: 0.85)
                                    : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8))
                        )
                    Text(fileName)
                        .etFont(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(
                            usesNoBubbleStyle
                                ? resolvedTextColor(default: Color.primary)
                                : resolvedTextColor(default: isOutgoing ? Color.white : Color.primary)
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            usesNoBubbleStyle
                                ? Color.clear
                                : (isOutgoing
                                    ? resolvedUserBubbleEndColor
                                    : (resolvedAssistantBubbleColor ?? Color(uiColor: .secondarySystemBackground)))
                        )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
    
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        let shouldRenderAsOutgoing = isOutgoing || isError
        ETAdvancedMarkdownRenderer(
            content: content,
            preparedContent: preparedMarkdownPayload,
            enableMarkdown: enableMarkdown,
            isOutgoing: shouldRenderAsOutgoing,
            enableAdvancedRenderer: enableAdvancedRenderer,
            enableMathRendering: enableMathRendering,
            customTextColor: customTextColorOverride
        )
    }
    
    @ViewBuilder
    private func audioPlayerView(fileName: String) -> some View {
        let foregroundColor = usesNoBubbleStyle
            ? resolvedTextColor(default: Color.primary)
            : resolvedTextColor(default: isOutgoing ? Color.white : Color.primary)
        let secondaryColor = usesNoBubbleStyle
            ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75)
            : (isOutgoing
                ? resolvedSecondaryTextColor(default: Color.white.opacity(0.7), customOpacity: 0.7)
                : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75))
        
        HStack(spacing: 12) {
            // 播放按钮
            Button {
                audioPlayer.togglePlayback(fileName: fileName)
            } label: {
                ZStack {
                    Circle()
                        .fill(usesNoBubbleStyle ? Color.secondary.opacity(0.15) : (isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15)))
                        .frame(width: 44, height: 44)
                    Image(systemName: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName ? "stop.fill" : "play.fill")
                        .etFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(foregroundColor)
                }
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                // 波形动画 / 进度条
                TelegramWaveformView(
                    progress: audioPlayer.currentFileName == fileName ? audioPlayer.progress : 0,
                    isPlaying: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName,
                    foregroundColor: foregroundColor,
                    backgroundColor: secondaryColor.opacity(0.4)
                )
                .frame(height: 20)
                
                // 时长
                if audioPlayer.currentFileName == fileName && audioPlayer.duration > 0 {
                    Text(audioPlayer.timeString)
                        .etFont(.caption2)
                        .foregroundStyle(secondaryColor)
                        .monospacedDigit()
                } else {
                    Text(fileName)
                        .etFont(.caption2)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 180)
    }
    
}

// MARK: - Telegram 输入指示器动画

struct TelegramTypingIndicator: View {
    @State private var animationPhase = 0
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                    .opacity(animationPhase == index ? 1 : 0.5)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: false)) {
                animationPhase = 3
            }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            animationPhase = (animationPhase + 1) % 3
        }
    }
}

// MARK: - Telegram 波形视图

struct TelegramWaveformView: View {
    let progress: Double
    let isPlaying: Bool
    let foregroundColor: Color
    let backgroundColor: Color
    
    private let barCount = 28
    private let heights: [CGFloat] = (0..<28).map { _ in CGFloat.random(in: 0.3...1.0) }
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let barProgress = Double(index) / Double(barCount)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barProgress <= progress ? foregroundColor : backgroundColor)
                        .frame(width: 2, height: geo.size.height * heights[index])
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Image Preview Wrapper

struct ImagePreviewWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

private enum ChatAttachmentImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        return cache
    }()

    static func image(for fileName: String) -> UIImage? {
        cache.object(forKey: fileName as NSString)
    }

    static func store(_ image: UIImage, for fileName: String) {
        let pixelCost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: fileName as NSString, cost: max(1, pixelCost))
    }
}

private struct AttachmentImageView: View {
    let fileName: String
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let onPreview: (UIImage) -> Void

    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    var body: some View {
        Group {
            if let image {
                Button {
                    onPreview(image)
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: minWidth, maxWidth: maxWidth)
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(minWidth: minWidth, maxWidth: maxWidth)
                    .frame(height: height)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo")
                                .etFont(.system(size: 20))
                                .foregroundStyle(.secondary)
                            Text("图片丢失")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
            }
        }
        .task(id: fileName) {
            guard !didAttemptLoad else { return }
            didAttemptLoad = true
            await loadImage()
        }
    }

    private func loadImage() async {
        if let cached = ChatAttachmentImageCache.image(for: fileName) {
            await MainActor.run {
                image = cached
            }
            return
        }

        let loadTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
            if let image = UIImage(contentsOfFile: fileURL.path) {
                return image
            }
            guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
            return UIImage(data: data)
        }
        let loadedImage = await loadTask.value

        guard let loadedImage else { return }
        ChatAttachmentImageCache.store(loadedImage, for: fileName)
        await MainActor.run {
            image = loadedImage
        }
    }
}

// MARK: - Audio Player Manager

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则播放状态与进度不会稳定自动刷新。
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentFileName: String?
    @Published var duration: TimeInterval = 0
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    
    var timeString: String {
        guard let player = audioPlayer else { return "0:00" }
        let current = Int(player.currentTime)
        let total = Int(player.duration)
        return String(format: "%d:%02d / %d:%02d", current / 60, current % 60, total / 60, total % 60)
    }
    
    func togglePlayback(fileName: String) {
        if isPlaying && currentFileName == fileName {
            stop()
        } else {
            play(fileName: fileName)
        }
    }
    
    func play(fileName: String) {
        stop()
        
        guard let data = Persistence.loadAudio(fileName: fileName) else {
            print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), fileName))
            return
        }
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            currentFileName = fileName
            duration = audioPlayer?.duration ?? 0
            isPlaying = true
            
            startTimer()
        } catch {
            // 播放音频失败
        }
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        progress = 0
        stopTimer()
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer else { return }
            self.progress = player.currentTime / player.duration
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.progress = 0
            self.stopTimer()
        }
    }
    
    deinit {
        stop()
    }
}

// MARK: - 思考与工具时间线

private struct AssistantTimelineStepShell<Content: View>: View {
    let iconName: String
    let iconColor: Color
    let lineColor: Color
    let isFirst: Bool
    let isLast: Bool
    private let content: Content

    init(
        iconName: String,
        iconColor: Color,
        lineColor: Color,
        isFirst: Bool,
        isLast: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.lineColor = lineColor
        self.isFirst = isFirst
        self.isLast = isLast
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .padding(.top, 7)
                .frame(width: 24)

            content
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .leading) {
            AssistantTimelineLineShape(isFirst: isFirst, isLast: isLast)
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssistantTimelineLineShape: Shape {
    let isFirst: Bool
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.midX
        let rowOverlap: CGFloat = 1
        let iconTopY: CGFloat = 8
        let iconBottomY: CGFloat = 28
        if !isFirst {
            path.move(to: CGPoint(x: x, y: rect.minY - rowOverlap))
            path.addLine(to: CGPoint(x: x, y: rect.minY + iconTopY))
        }
        if !isLast {
            path.move(to: CGPoint(x: x, y: rect.minY + iconBottomY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + rowOverlap))
        }
        return path
    }
}

private struct TimelineReasoningStepView: View {
    let reasoning: String
    @Binding var isExpanded: Bool
    let isShimmering: Bool
    let customTextColor: Color?
    let usesNoBubbleStyle: Bool
    let reasoningStartedAt: Date?
    let reasoningCompletedAt: Date?
    let reasoningSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    headerTitleView
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .etFont(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(secondaryColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .etFont(.subheadline, sampleText: reasoning)
                    .foregroundStyle(secondaryColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var titleColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.92)
        }
        return usesNoBubbleStyle ? .primary.opacity(0.88) : .primary.opacity(0.82)
    }

    private var secondaryColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return .secondary.opacity(0.92)
    }

    @ViewBuilder
    private var headerTitleView: some View {
        if let reasoningStartedAt, reasoningCompletedAt == nil {
            TimelineView(.periodic(from: reasoningStartedAt, by: 1)) { context in
                headerTitleLabel(title: reasoningHeaderTitle(referenceDate: context.date))
            }
        } else {
            headerTitleLabel(title: reasoningHeaderTitle(referenceDate: reasoningCompletedAt ?? Date()))
        }
    }

    @ViewBuilder
    private func headerTitleLabel(title: String) -> some View {
        if isShimmering {
            ShimmeringText(
                text: title,
                font: .subheadline.weight(.semibold),
                baseColor: secondaryColor,
                highlightColor: titleColor
            )
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(title)
                .etFont(.subheadline.weight(.semibold))
                .foregroundStyle(titleColor)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reasoningHeaderTitle(referenceDate: Date) -> String {
        var title = NSLocalizedString("深度思考", comment: "Timeline reasoning step title")
        if let elapsed = reasoningElapsedSeconds(referenceDate: referenceDate) {
            title += String(format: "（%.1f秒）", elapsed)
        }
        guard let summary = reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return title
        }
        return "\(title)：\(summary)"
    }

    private func reasoningElapsedSeconds(referenceDate: Date) -> Double? {
        guard let reasoningStartedAt else { return nil }
        let finishedAt = reasoningCompletedAt ?? referenceDate
        return max(0, finishedAt.timeIntervalSince(reasoningStartedAt))
    }
}

private struct TimelineToolCallStepContent: View {
    let label: String
    let statusTitle: String
    let statusIconName: String
    let statusColor: Color
    let summary: String?
    let showPendingGuidance: Bool
    let customTextColor: Color?

    private var titleText: String {
        "\(NSLocalizedString("调用工具", comment: "Tool call timeline title"))：\(label)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showPendingGuidance {
                    ToolCallPendingGuidanceLabel(text: titleText, color: titleColor)
                } else {
                    Text(titleText)
                        .etFont(.subheadline.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .etFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryColor)
            }

            HStack(spacing: 4) {
                Image(systemName: statusIconName)
                    .etFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .etFont(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }

            if let summary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(summary)
                    .etFont(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .contentShape(Rectangle())
    }

    private var titleColor: Color {
        customTextColor?.opacity(0.92) ?? .primary.opacity(0.82)
    }

    private var secondaryColor: Color {
        customTextColor?.opacity(0.76) ?? .secondary.opacity(0.9)
    }
}

// MARK: - 思考过程折叠视图（性能优化）

/// 独立的思考过程视图，避免长文本导致父视图重复布局
/// 使用 Equatable 优化：只有在 reasoning 或 isExpanded 变化时才重新渲染
struct ReasoningDisclosureView: View, Equatable {
    let reasoning: String
    @Binding var isExpanded: Bool
    let isOutgoing: Bool
    let usesNoBubbleStyle: Bool
    let isShimmering: Bool
    let customTextColor: Color?
    let reasoningStartedAt: Date?
    let reasoningCompletedAt: Date?
    let reasoningSummary: String?
    
    static func == (lhs: ReasoningDisclosureView, rhs: ReasoningDisclosureView) -> Bool {
        lhs.reasoning == rhs.reasoning
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.usesNoBubbleStyle == rhs.usesNoBubbleStyle
            && lhs.isShimmering == rhs.isShimmering
            && Self.colorSignature(lhs.customTextColor) == Self.colorSignature(rhs.customTextColor)
            && lhs.reasoningStartedAt == rhs.reasoningStartedAt
            && lhs.reasoningCompletedAt == rhs.reasoningCompletedAt
            && lhs.reasoningSummary == rhs.reasoningSummary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let baseColor: Color = resolvedSecondaryTextColor(
                default: usesNoBubbleStyle
                    ? .secondary
                    : (isOutgoing ? Color.white.opacity(0.9) : Color.secondary),
                customTextColor: customTextColor,
                customOpacity: 0.9
            )
            let highlightColor: Color = resolvedTextColor(
                default: usesNoBubbleStyle
                    ? .primary.opacity(0.85)
                    : (isOutgoing ? Color.white : Color.primary.opacity(0.85)),
                customTextColor: customTextColor,
                customOpacity: 0.92
            )
            // 点击区域：标题行
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .etFont(.system(size: 12))
                        .foregroundStyle(baseColor)
                        .padding(.top, 2)
                    headerTitleView(baseColor: baseColor, highlightColor: highlightColor)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .etFont(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(baseColor)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // 内容区域：只在展开时渲染
            if isExpanded {
                Text(reasoning)
                    .etFont(.subheadline, sampleText: reasoning)
                    .foregroundStyle(
                        resolvedSecondaryTextColor(
                            default: usesNoBubbleStyle
                                ? Color.secondary
                                : (isOutgoing ? Color.white.opacity(0.85) : Color.secondary),
                            customTextColor: customTextColor,
                            customOpacity: 0.85
                        )
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private func resolvedTextColor(default defaultColor: Color, customTextColor: Color?, customOpacity: Double) -> Color {
        if let customTextColor {
            return customTextColor.opacity(customOpacity)
        }
        return defaultColor
    }

    private func resolvedSecondaryTextColor(default defaultColor: Color, customTextColor: Color?, customOpacity: Double) -> Color {
        resolvedTextColor(default: defaultColor, customTextColor: customTextColor, customOpacity: customOpacity)
    }

    @ViewBuilder
    private func headerTitleView(baseColor: Color, highlightColor: Color) -> some View {
        if let reasoningStartedAt, reasoningCompletedAt == nil {
            TimelineView(.periodic(from: reasoningStartedAt, by: 1)) { context in
                headerTitleLabel(
                    title: reasoningHeaderTitle(referenceDate: context.date),
                    baseColor: baseColor,
                    highlightColor: highlightColor
                )
            }
        } else {
            headerTitleLabel(
                title: reasoningHeaderTitle(referenceDate: reasoningCompletedAt ?? Date()),
                baseColor: baseColor,
                highlightColor: highlightColor
            )
        }
    }

    @ViewBuilder
    private func headerTitleLabel(title: String, baseColor: Color, highlightColor: Color) -> some View {
        if isShimmering {
            ShimmeringText(
                text: title,
                font: .subheadline.weight(.medium),
                baseColor: baseColor,
                highlightColor: highlightColor
            )
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(title)
                .etFont(.subheadline.weight(.medium))
                .foregroundStyle(baseColor)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reasoningHeaderTitle(referenceDate: Date) -> String {
        let baseTitle: String
        if let elapsedSeconds = reasoningElapsedSeconds(referenceDate: referenceDate) {
            baseTitle = "已经思考\(elapsedSeconds)秒"
        } else {
            baseTitle = "思考过程"
        }

        guard let summary = reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return baseTitle
        }
        return "\(baseTitle)：\(summary)"
    }

    private func reasoningElapsedSeconds(referenceDate: Date) -> Int? {
        guard let reasoningStartedAt else { return nil }
        let finishedAt = reasoningCompletedAt ?? referenceDate
        let elapsed = max(0, finishedAt.timeIntervalSince(reasoningStartedAt))
        if elapsed == 0 {
            return 0
        }
        return max(1, Int(elapsed.rounded(.down)))
    }

    private static func colorSignature(_ color: Color?) -> String? {
        guard let color else { return nil }
        return ChatAppearanceColorCodec.hexRGBA(from: color)
    }
}

// MARK: - 工具调用摘要行
private struct ToolCallSummaryBubbleRow: View {
    let label: String
    let statusTitle: String
    let statusIconName: String
    let statusColor: Color
    let showPendingGuidance: Bool
    let isOutgoing: Bool
    let customTextColor: Color?

    private var baseForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.92)
        }
        return isOutgoing ? Color.white.opacity(0.92) : Color.secondary
    }

    private var secondaryForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return isOutgoing ? Color.white.opacity(0.78) : Color.secondary.opacity(0.9)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                if showPendingGuidance {
                    ToolCallPendingGuidanceLabel(text: label, color: baseForegroundColor)
                } else {
                    Text(label)
                        .etFont(.subheadline.weight(.medium))
                        .foregroundStyle(baseForegroundColor)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: statusIconName)
                        .etFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(statusTitle)
                        .etFont(.caption)
                        .foregroundStyle(secondaryForegroundColor)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondaryForegroundColor)
        }
        .contentShape(Rectangle())
    }
}

private struct ToolCallPendingGuidanceLabel: View {
    let text: String
    let color: Color
    @State private var shouldBounce = false

    var body: some View {
        ShimmeringText(
            text: text,
            font: .subheadline.weight(.medium),
            baseColor: color.opacity(0.75),
            highlightColor: color
        )
        .lineLimit(1)
        .offset(y: shouldBounce ? -1.5 : 1.5)
        .animation(
            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
            value: shouldBounce
        )
        .onAppear {
            shouldBounce = true
        }
    }
}

private struct ToolPermissionInlineView: View {
    let request: ToolPermissionRequest
    let onDecision: (ToolPermissionDecision) -> Void
    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    private var countdownText: String? {
        guard let remaining = permissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return "将在 \(remaining)s 后自动允许"
    }

    private var autoApproveToggleLabel: String {
        permissionCenter.isAutoApproveDisabled(for: request.toolName)
            ? "恢复该工具自动批准"
            : "关闭该工具自动批准"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("允许") {
                    onDecision(.allowOnce)
                }
                .buttonStyle(.borderedProminent)

                Button("拒绝", role: .destructive) {
                    onDecision(.deny)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("补充提示") {
                    onDecision(.supplement)
                }
                .buttonStyle(.bordered)

                Button("保持允许") {
                    onDecision(.allowForTool)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("完全权限") {
                    onDecision(.allowAll)
                }
                .buttonStyle(.bordered)

                if permissionCenter.autoApproveEnabled {
                    Button(autoApproveToggleLabel) {
                        let shouldDisable = !permissionCenter.isAutoApproveDisabled(for: request.toolName)
                        permissionCenter.setAutoApproveDisabled(shouldDisable, for: request.toolName)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let countdownText {
                Text(countdownText)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }
}

struct ToolResultsDisclosureView: View, Equatable {
    let toolCalls: [InternalToolCall]
    let resultText: String
    @Binding var isExpanded: Bool
    let isOutgoing: Bool
    let isPending: Bool
    let enableExperimentalToolResultDisplay: Bool
    let customTextColor: Color?
    
    static func == (lhs: ToolResultsDisclosureView, rhs: ToolResultsDisclosureView) -> Bool {
        lhs.toolCalls.map(\.id) == rhs.toolCalls.map(\.id)
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.resultText == rhs.resultText
            && lhs.isPending == rhs.isPending
            && lhs.enableExperimentalToolResultDisplay == rhs.enableExperimentalToolResultDisplay
            && Self.colorSignature(lhs.customTextColor) == Self.colorSignature(rhs.customTextColor)
    }

    private func displayName(for toolName: String) -> String {
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        if let label = MCPManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = ShortcutToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = SkillManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = AppToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        return toolName
    }

    private var headerForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.9)
        }
        return isOutgoing ? Color.white.opacity(0.9) : Color.secondary
    }

    private var summaryForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.72)
        }
        return isOutgoing ? Color.white.opacity(0.72) : Color.secondary.opacity(0.9)
    }

    private var sectionForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return isOutgoing ? Color.white.opacity(0.78) : Color.secondary
    }

    private var sectionBackgroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(isOutgoing ? 0.15 : 0.1)
        }
        return isOutgoing ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1)
    }

    private func resolvedResult(for call: InternalToolCall) -> String {
        (call.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayModel(for call: InternalToolCall) -> MCPToolResultDisplayModel {
        MCPToolResultFormatter.displayModel(from: resolvedResult(for: call))
    }

    private var disclosureSummaryText: String? {
        guard enableExperimentalToolResultDisplay else { return nil }
        let summaries = toolCalls
            .map { call -> String in
                if let payload = widgetPayload(for: call) {
                    if let title = payload.title,
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return "可视化 Widget · \(title)"
                    }
                    return "可视化 Widget"
                }
                return displayModel(for: call).summaryText
            }
            .filter { !$0.isEmpty }

        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: " · ")
    }
    
    var body: some View {
        let toolNames = toolCalls.map { displayName(for: $0.toolName) }
        VStack(alignment: .leading, spacing: 0) {
            if isPending {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .etFont(.system(size: 12))
                    ShimmeringText(
                        text: "结果：\(toolNames.joined(separator: ", "))",
                        font: .subheadline.weight(.medium),
                        baseColor: headerForegroundColor,
                        highlightColor: customTextColor?.opacity(0.95) ?? (isOutgoing ? Color.white : Color.primary.opacity(0.85))
                    )
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .etFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.4) : Color.secondary.opacity(0.6))
                }
                .foregroundStyle(headerForegroundColor)
                .contentShape(Rectangle())
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                                .etFont(.system(size: 12))
                            Text("结果：\(toolNames.joined(separator: ", "))")
                                .etFont(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .etFont(.system(size: 12, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        if let disclosureSummaryText {
                            Text(disclosureSummaryText)
                                .etFont(.caption)
                                .foregroundStyle(summaryForegroundColor)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .foregroundStyle(headerForegroundColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded && !isPending {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls, id: \.id) { call in
                        toolResultContent(for: call)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    @ViewBuilder
    private func toolResultContent(for call: InternalToolCall) -> some View {
        if let payload = widgetPayload(for: call) {
            widgetToolResultContent(for: call, payload: payload)
        } else if enableExperimentalToolResultDisplay {
            experimentalToolResultContent(for: call)
        } else {
            legacyToolResultContent(for: call)
        }
    }

    private func widgetPayload(for call: InternalToolCall) -> ToolWidgetPayload? {
        if let payload = ToolWidgetPayloadParser.parse(from: call.arguments) {
            return payload
        }

        let resolved = resolvedResult(for: call)
        if let payload = ToolWidgetPayloadParser.parse(from: resolved) {
            return payload
        }

        if let payload = ToolWidgetPayloadParser.parse(from: resultText) {
            return payload
        }

        return nil
    }

    @ViewBuilder
    private func widgetToolResultContent(for call: InternalToolCall, payload: ToolWidgetPayload) -> some View {
        if call.toolName == AppToolKind.showWidget.toolName {
            ToolWidgetRendererCard(payload: payload)
        } else {
        let display = displayModel(for: call)
        let label = displayName(for: call.toolName)
            VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            ToolWidgetRendererCard(payload: payload)
            if display.shouldShowRawSection {
                Divider()
                    .background(sectionBackgroundColor.opacity(0.7))
                toolResultSection(
                    title: "原始返回",
                    text: display.rawDisplayText,
                    font: .system(.caption, design: .monospaced),
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
        }
    }

    private func experimentalToolResultContent(for call: InternalToolCall) -> some View {
        let display = displayModel(for: call)
        let label = displayName(for: call.toolName)
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            if let primaryContentText = display.primaryContentText,
               !primaryContentText.isEmpty {
                toolResultSection(
                    title: display.shouldShowRawSection ? "主要内容" : "结果内容",
                    text: primaryContentText,
                    font: .caption,
                    enableSelection: true
                )
            }
            if display.shouldShowRawSection {
                if display.primaryContentText != nil {
                    Divider()
                        .background(sectionBackgroundColor.opacity(0.7))
                }
                toolResultSection(
                    title: "原始返回",
                    text: display.rawDisplayText,
                    font: .system(.caption, design: .monospaced),
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
    }

    private func legacyToolResultContent(for call: InternalToolCall) -> some View {
        let result = resolvedResult(for: call)
        let label = displayName(for: call.toolName)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            if !result.isEmpty {
                CappedScrollableText(
                    text: result,
                    maxHeight: 200,
                    font: .caption,
                    foreground: sectionForegroundColor,
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
    }

    private func toolResultSection(
        title: String,
        text: String,
        font: Font,
        enableSelection: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(sectionForegroundColor.opacity(0.85))
            CappedScrollableText(
                text: text,
                maxHeight: 200,
                font: font,
                foreground: sectionForegroundColor,
                enableSelection: enableSelection
            )
        }
    }

    private static func colorSignature(_ color: Color?) -> String? {
        guard let color else { return nil }
        return ChatAppearanceColorCodec.hexRGBA(from: color)
    }
}

private struct ToolWidgetRendererCard: View {
    let payload: ToolWidgetPayload

    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedHeight: CGFloat = 180
    @State private var hasRendered = false

    private var loadingText: String {
        payload.loadingMessages.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (payload.loadingMessages.first ?? "正在渲染 Widget…")
            : "正在渲染 Widget…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ToolWidgetWebView(
                    widgetCode: payload.widgetCode,
                    colorScheme: colorScheme,
                    availableWidth: max(1, floor(proxy.size.width)),
                    renderedHeight: $renderedHeight,
                    hasRendered: $hasRendered
                )
            }
            .frame(height: max(120, renderedHeight))
            .overlay {
                if !hasRendered {
                    ProgressView(loadingText)
                        .progressViewStyle(.circular)
                        .tint(.secondary)
                        .etFont(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
        }
    }
}

private struct ToolWidgetWebView: UIViewRepresentable {
    let widgetCode: String
    let colorScheme: ColorScheme
    let availableWidth: CGFloat
    @Binding var renderedHeight: CGFloat
    @Binding var hasRendered: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(renderedHeight: $renderedHeight, hasRendered: $hasRendered)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.heightMessageName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let stableWidth = max(1, floor(availableWidth))
        let html = wrappedHTML(widgetCode: widgetCode, stableWidth: stableWidth)
        let renderKey = "\(colorScheme == .dark ? "dark" : "light")|\(html)"
        guard context.coordinator.lastRenderKey != renderKey else { return }
        context.coordinator.lastRenderKey = renderKey

        DispatchQueue.main.async {
            hasRendered = false
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessageName)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightMessageName = "etWidgetHeight"

        @Binding var renderedHeight: CGFloat
        @Binding var hasRendered: Bool
        var lastRenderKey: String?

        init(renderedHeight: Binding<CGFloat>, hasRendered: Binding<Bool>) {
            self._renderedHeight = renderedHeight
            self._hasRendered = hasRendered
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.heightMessageName else { return }
            guard let value = message.body as? Double else { return }
            let nextHeight = max(120, ceil(value))
            if abs(renderedHeight - nextHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.renderedHeight = nextHeight
                    self.hasRendered = true
                }
            } else {
                DispatchQueue.main.async {
                    self.hasRendered = true
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.__etReportSize && window.__etReportSize();", completionHandler: nil)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async {
                self.hasRendered = true
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async {
                self.hasRendered = true
            }
        }
    }

    private func wrappedHTML(widgetCode: String, stableWidth: CGFloat) -> String {
        """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <style id="et-widget-host-style">
    :root {
      color-scheme: light dark;
      --color-background-primary: #FFFFFF;
      --color-background-secondary: #F2F2F7;
      --color-background-tertiary: #FFFFFF;
      --color-text-primary: #1C1C1E;
      --color-text-secondary: #3C3C43;
      --color-text-tertiary: #8E8E93;
      --color-text-info: #0A84FF;
      --color-border-tertiary: rgba(60, 60, 67, 0.16);
      --color-border-secondary: rgba(60, 60, 67, 0.3);
      --border-radius-md: 8px;
      --border-radius-lg: 12px;
      --border-radius-xl: 16px;
      --font-sans: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
      --font-serif: Georgia, 'Times New Roman', serif;
      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --color-background-primary: #1C1C1E;
        --color-background-secondary: #2C2C2E;
        --color-background-tertiary: #1C1C1E;
        --color-text-primary: #FFFFFF;
        --color-text-secondary: #EBEBF5;
        --color-text-tertiary: #8E8E93;
        --color-text-info: #5AC8FA;
        --color-border-tertiary: rgba(235, 235, 245, 0.16);
        --color-border-secondary: rgba(235, 235, 245, 0.3);
      }
    }
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: auto;
      min-height: 0;
      background: transparent;
      overflow: visible;
    }
    body {
      position: relative;
    }
    #et-widget-host {
      width: min(100%, \(Int(stableWidth))px);
      max-width: 100%;
      min-height: 1px;
      box-sizing: border-box;
      overflow: visible;
    }
    #et-widget-root {
      width: 100%;
      min-width: 0;
      max-width: 100%;
      margin: 0;
      box-sizing: border-box;
      overflow: visible;
    }
  </style>
</head>
<body>
  <div id="et-widget-host">
    <div id="et-widget-root">
\(widgetCode)
    </div>
  </div>
  <script>
    (function () {
      var lastPostedHeight = 0;
      var sampleCount = 0;

      function isFiniteNumber(value) {
        return typeof value === 'number' && isFinite(value);
      }

      function walkElements(rootNode, visitor) {
        if (!rootNode || typeof rootNode.querySelectorAll !== 'function') return;
        var elements = rootNode.querySelectorAll('*');
        for (var index = 0; index < elements.length; index += 1) {
          var element = elements[index];
          visitor(element);
          if (element && element.shadowRoot) {
            walkElements(element.shadowRoot, visitor);
          }
        }
      }

      function syncSameOriginIframeHeight() {
        var iframes = document.querySelectorAll('iframe');
        for (var index = 0; index < iframes.length; index += 1) {
          var frame = iframes[index];
          if (!frame) continue;
          try {
            var frameDocument = frame.contentDocument;
            if (!frameDocument) continue;
            var frameBody = frameDocument.body;
            var frameRoot = frameDocument.documentElement;
            var frameHeight = Math.max(
              frameBody ? frameBody.scrollHeight : 0,
              frameBody ? frameBody.offsetHeight : 0,
              frameRoot ? frameRoot.scrollHeight : 0,
              frameRoot ? frameRoot.offsetHeight : 0
            );
            if (frameHeight > 0) {
              frame.style.height = frameHeight + 'px';
            }
          } catch (_) {
            // 跨域 iframe 无法读取高度，保持默认行为。
          }
        }
      }

      function visualBoundsHeight(container) {
        if (!container || typeof container.getBoundingClientRect !== 'function') return 0;
        var containerRect = container.getBoundingClientRect();
        var minTop = isFiniteNumber(containerRect.top) ? containerRect.top : 0;
        var maxBottom = isFiniteNumber(containerRect.bottom) ? containerRect.bottom : minTop;
        walkElements(container, function (element) {
          if (!element || typeof element.getBoundingClientRect !== 'function') return;
          var rect = element.getBoundingClientRect();
          if (!rect) return;
          if (!isFiniteNumber(rect.top) || !isFiniteNumber(rect.bottom)) return;
          if (rect.width <= 0 && rect.height <= 0) return;
          if (rect.top < minTop) minTop = rect.top;
          if (rect.bottom > maxBottom) maxBottom = rect.bottom;
        });
        return Math.max(0, Math.ceil(maxBottom - minTop));
      }

      function postHeight(height) {
        if (!isFiniteNumber(height)) return;
        if (Math.abs(height - lastPostedHeight) < 0.5) return;
        lastPostedHeight = height;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.etWidgetHeight) {
          window.webkit.messageHandlers.etWidgetHeight.postMessage(height);
        }
      }

      function reportHeight() {
        syncSameOriginIframeHeight();
        var host = document.getElementById('et-widget-host');
        var widgetRoot = document.getElementById('et-widget-root');
        var flowHeight = Math.max(
          host ? host.scrollHeight : 0,
          host ? host.offsetHeight : 0,
          widgetRoot ? widgetRoot.scrollHeight : 0,
          widgetRoot ? widgetRoot.offsetHeight : 0
        );
        var visualHeight = visualBoundsHeight(widgetRoot || host);
        var height = Math.max(1, flowHeight, visualHeight);
        var viewportHeight = window.innerHeight || 0;
        if (
          lastPostedHeight > 0 &&
          viewportHeight > 0 &&
          Math.abs(viewportHeight - lastPostedHeight) < 1 &&
          height > lastPostedHeight
        ) {
          var feedbackGrowth = height - viewportHeight;
          if (feedbackGrowth > 0 && feedbackGrowth <= 96) {
            height = lastPostedHeight;
          }
        }
        postHeight(height);
      }
      window.__etReportSize = reportHeight;
      if (window.ResizeObserver) {
        var observer = new ResizeObserver(reportHeight);
        var hostContainer = document.getElementById('et-widget-host');
        var widgetContainer = document.getElementById('et-widget-root');
        if (hostContainer) observer.observe(hostContainer);
        if (widgetContainer) observer.observe(widgetContainer);
      }
      if (window.MutationObserver) {
        var mutationObserver = new MutationObserver(reportHeight);
        var mutationTarget = document.getElementById('et-widget-host') || document.documentElement;
        if (mutationTarget) {
          mutationObserver.observe(mutationTarget, {
            attributes: true,
            characterData: true,
            childList: true,
            subtree: true
          });
        }
      }
      window.addEventListener('load', reportHeight);
      window.addEventListener('resize', reportHeight);
      setTimeout(reportHeight, 0);
      setTimeout(reportHeight, 120);
      setTimeout(reportHeight, 360);
      function sampleAnimatedLayout() {
        reportHeight();
        sampleCount += 1;
        if (sampleCount < 20) {
          setTimeout(sampleAnimatedLayout, 100);
        }
      }
      sampleAnimatedLayout();
    })();
  </script>
</body>
</html>
"""
    }
}

private struct ShimmeringText: View {
    let text: String
    let font: Font
    let baseColor: Color
    let highlightColor: Color
    var duration: Double = 1.6
    var angle: Double = 18
    var bandWidthRatio: CGFloat = 0.6
    var bandHeightRatio: CGFloat = 1.6

    @State private var isAnimating = false

    var body: some View {
        Text(text)
            .etFont(font)
            .foregroundStyle(baseColor)
            .overlay(
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let bandWidth = max(1, width * bandWidthRatio)
                    let bandHeight = max(1, height * bandHeightRatio)
                    let startX = -bandWidth
                    let endX = width + bandWidth
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: highlightColor, location: 0.35),
                                    .init(color: highlightColor, location: 0.65),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: bandWidth, height: bandHeight)
                        .rotationEffect(.degrees(angle))
                        .position(x: isAnimating ? endX : startX, y: height / 2)
                        .blendMode(.screen)
                }
                .mask(
                    Text(text)
                        .etFont(font)
                )
                .allowsHitTesting(false)
            )
            .onAppear {
                guard !isAnimating else { return }
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

private struct CappedScrollableText: View {
    let text: String
    let maxHeight: CGFloat
    let font: Font
    let foreground: Color
    let enableSelection: Bool
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            textView
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: resolvedHeight)
        .onPreferenceChange(TextHeightKey.self) { measuredHeight = $0 }
    }

    private var resolvedHeight: CGFloat {
        guard measuredHeight > 0 else { return maxHeight }
        return min(measuredHeight, maxHeight)
    }

    @ViewBuilder
    private var textView: some View {
        if enableSelection {
            Text(text)
                .etFont(font)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .etFont(font)
                .foregroundStyle(foreground)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
