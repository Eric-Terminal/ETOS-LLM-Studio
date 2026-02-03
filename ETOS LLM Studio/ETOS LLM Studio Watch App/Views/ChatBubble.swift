// ============================================================================
// ChatBubble.swift
// ============================================================================
// ETOS LLM Studio Watch App 聊天气泡视图 (已重构)
//
// 功能特性:
// - 根据角色（用户/AI/错误）显示不同样式的气泡
// - 支持 Markdown 渲染
// - 思考过程的展开/折叠状态由外部传入的绑定控制
// - 支持语音消息播放
// ============================================================================

import SwiftUI
import WatchKit
import Foundation
import MarkdownUI
import Shared
import AVFoundation
import Combine

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

/// 聊天消息气泡组件
struct ChatBubble: View {
    
    // MARK: - 属性与绑定
    
    let message: ChatMessage
    @Binding var isReasoningExpanded: Bool
    @Binding var isToolCallsExpanded: Bool
    
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    
    @StateObject private var audioPlayer = WatchAudioPlayerManager()
    @State private var imagePreview: ImagePreviewPayload?
    @State private var availableWidth: CGFloat = 0
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    /// 图片占位符文本（各语言版本）
    private static let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]

    private var hasNonPlaceholderText: Bool {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        return !Self.imagePlaceholders.contains(trimmedContent)
    }
    
    private var hasToolCalls: Bool {
        !(message.toolCalls ?? []).isEmpty
    }
    
    private var hasToolResults: Bool {
        let hasCallResults = message.toolCalls?.contains { call in
            !(call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        if message.role == .tool {
            let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasCallResults || hasContent
        }
        return hasCallResults
    }

    private var hasPendingToolResults: Bool {
        guard message.role != .tool else { return false }
        guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return false }
        guard !hasToolResults else { return false }
        return activeToolPermissionRequest == nil
    }

    private var shouldShimmerReasoningHeader: Bool {
        guard viewModel.isSendingMessage, message.role == .assistant else { return false }
        let latestAssistantID = viewModel.messages.last(where: { $0.role == .assistant })?.id
        return latestAssistantID == message.id
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

    private var assistantBubbleShape: BubbleCornerShape {
        let baseRadius: CGFloat = 12
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
        mergeWithPrevious && message.role != .user && message.role != .error
    }

    private var separatorThickness: CGFloat {
        1 / displayScale
    }

    private var separatorColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    private var separatorLine: some View {
        Rectangle()
            .fill(separatorColor)
            .frame(height: separatorThickness)
    }

    private var bubbleMaxWidth: CGFloat {
        let baseWidth = availableWidth > 0 ? availableWidth : WKInterfaceDevice.current().screenBounds.width
        return baseWidth * 0.86
    }

    private var shouldForceMergedWidth: Bool {
        message.role != .user && message.role != .error && (mergeWithPrevious || mergeWithNext)
    }
    
    private var activeToolPermissionRequest: ToolPermissionRequest? {
        guard message.role != .user,
              let request = toolPermissionCenter.activeRequest,
              let toolCalls = message.toolCalls else {
            return nil
        }
        let trimmedArgs = request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = toolCalls.contains { call in
            call.toolName == request.toolName
                && call.arguments.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedArgs
        }
        return matches ? request : nil
    }


    // MARK: - 视图主体
    
    var body: some View {
        HStack {
            // 重构: 使用 MessageRole 枚举进行判断
            switch message.role {
            case .user:
                Spacer()
                userBubble
            case .error:
                errorBubble
                Spacer()
            case .assistant, .system, .tool: // system 和 tool 也使用 assistant 样式
                assistantBubble
                Spacer()
            @unknown default:
                // 为未来可能增加的 role 类型提供一个默认的回退，防止编译错误
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.top, mergeWithPrevious ? 0 : 4)
        .padding(.bottom, mergeWithNext ? 0 : 4)
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
                    .padding(12)
            }
        }
    }

    private struct RowWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
    
    // MARK: - 气泡视图
    
    @ViewBuilder
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                imageAttachmentsView(fileNames: imageFileNames, isOutgoing: true)
            }

            if shouldShowUserBubble {
                userTextBubble
            }
        }
    }
    
    @ViewBuilder
    private var errorBubble: some View {
        let content = Text(message.content)
            .padding(10)
            .foregroundColor(.white)

        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background(Color.red.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                errorBubbleFallback(content)
            }
        } else {
            errorBubbleFallback(content)
        }
    }
    
    @ViewBuilder
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                imageAttachmentsView(fileNames: imageFileNames, isOutgoing: false)
            }

            if shouldShowAssistantBubble {
                assistantTextBubble
            }
        }
    }

    @ViewBuilder
    private var userTextBubble: some View {
        let content = Group {
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName, isUser: true)
            } else if hasNonPlaceholderText {
                renderContent(message.content)
            }
        }
        .padding(10)
        .foregroundColor(.white)

        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background(Color.blue.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                userBubbleFallback(content)
            }
        } else {
            userBubbleFallback(content)
        }
    }

    @ViewBuilder
    private var assistantTextBubble: some View {
        if message.role == .tool {
            let content = VStack(alignment: .leading, spacing: 6) {
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    toolCallsInlineView(toolCalls)
                    if activeToolPermissionRequest != nil {
                        toolPermissionInlineView(onDecision: { decision in
                            toolPermissionCenter.resolveActiveRequest(with: decision)
                        })
                    }
                    let shouldShowResults = hasToolResults || hasPendingToolResults
                    if shouldShowResults {
                        toolResultsDisclosureView(
                            toolCalls,
                            resultText: message.content,
                            isPending: hasPendingToolResults
                        )
                    }
                } else if hasNonPlaceholderText {
                    renderContent(message.content)
                }
            }
            .padding(10)
            
            assistantBubbleContainer(content, isError: false)
            .contentShape(Rectangle())
        } else {
            let hasReasoning = message.reasoningContent != nil && !message.reasoningContent!.isEmpty
            let isErrorVersion = message.content.hasPrefix("重试失败")

            let content = VStack(alignment: .leading, spacing: 8) {
                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                    reasoningView(reasoning)
                }

                if shouldShowToolCallsBeforeContent {
                    toolCallsSection
                }

                if hasReasoning && hasNonPlaceholderText {
                    Divider().background(Color.gray)
                }

                if hasNonPlaceholderText {
                    renderContent(message.content)
                        .foregroundColor(isErrorVersion ? .white : nil)
                }

                if shouldShowToolCallsAfterContent {
                    toolCallsSection
                }

                if shouldShowThinkingIndicator {
                    if viewModel.isSendingMessage {
                        ShimmeringText(
                            text: currentThinkingText,
                            font: .caption,
                            baseColor: .secondary,
                            highlightColor: .primary.opacity(0.85)
                        )
                    } else {
                        Text(currentThinkingText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)

            assistantBubbleContainer(content, isError: isErrorVersion)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var toolCallsSection: some View {
        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            toolCallsInlineView(toolCalls)
            if activeToolPermissionRequest != nil {
                toolPermissionInlineView(onDecision: { decision in
                    toolPermissionCenter.resolveActiveRequest(with: decision)
                })
            }
            let shouldShowResults = hasToolResults || hasPendingToolResults
            if shouldShowResults {
                toolResultsDisclosureView(
                    toolCalls,
                    resultText: "",
                    isPending: hasPendingToolResults
                )
            }
        }
    }

    private var shouldShowUserBubble: Bool {
        message.audioFileName != nil || hasNonPlaceholderText
    }

    private var shouldShowAssistantBubble: Bool {
        let hasReasoning = message.reasoningContent != nil && !(message.reasoningContent ?? "").isEmpty
        if message.role == .tool {
            return hasToolCalls || hasNonPlaceholderText
        }
        return hasToolCalls || hasReasoning || hasNonPlaceholderText || shouldShowThinkingIndicator
    }
    
    // MARK: - 辅助视图
    
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        if enableMarkdown {
            Markdown(content)
                .markdownSoftBreakMode(.lineBreak)
        } else {
            Text(content)
        }
    }
    
    @ViewBuilder
    private func audioPlayerView(fileName: String, isUser: Bool) -> some View {
        let foregroundColor = isUser ? Color.white : Color.primary
        let secondaryColor = isUser ? Color.white.opacity(0.7) : Color.secondary
        let isCurrentFile = audioPlayer.currentFileName == fileName
        
        VStack(alignment: .leading, spacing: 4) {
            // 播放按钮 + 文件名
            HStack(spacing: 6) {
                Button {
                    audioPlayer.togglePlayback(fileName: fileName)
                } label: {
                    Image(systemName: audioPlayer.isPlaying && isCurrentFile ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(foregroundColor)
                }
                .buttonStyle(.plain)
                
                Text(fileName)
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            
            // 进度条 + 时间
            if isCurrentFile && audioPlayer.duration > 0 {
                ProgressView(value: audioPlayer.progress)
                    .progressViewStyle(.linear)
                    .tint(foregroundColor)
                
                HStack {
                    Text(formatTime(audioPlayer.currentTime))
                    Spacer()
                    Text(formatTime(audioPlayer.duration))
                }
                .font(.system(size: 9))
                .foregroundStyle(secondaryColor)
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private func imageAttachmentsView(fileNames: [String], isOutgoing: Bool) -> some View {
        let columns: [GridItem] = fileNames.count == 1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
        let itemHeight: CGFloat = fileNames.count == 1 ? 120 : 70

        LazyVGrid(columns: columns, alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
            ForEach(fileNames, id: \.self) { fileName in
                AttachmentImageView(
                    fileName: fileName,
                    height: itemHeight
                ) { image in
                    imagePreview = ImagePreviewPayload(image: image)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
    
    @ViewBuilder
    private func reasoningView(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                withAnimation {
                    isReasoningExpanded.toggle()
                }
            }) {
                HStack {
                    if shouldShimmerReasoningHeader {
                        ShimmeringText(
                            text: "思考过程",
                            font: .footnote,
                            baseColor: .secondary,
                            highlightColor: .primary.opacity(0.85)
                        )
                        .lineLimit(1)
                    } else {
                        Text("思考过程")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isReasoningExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isReasoningExpanded {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, isReasoningExpanded ? 5 : 0)
    }

    private func toolDisplayLabel(for toolName: String) -> String {
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        return MCPManager.shared.displayLabel(for: toolName) ?? toolName
    }
    
    @ViewBuilder
    private func toolCallsInlineView(_ toolCalls: [InternalToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(toolCalls, id: \.id) { toolCall in
                let label = toolDisplayLabel(for: toolCall.toolName)
                ToolCallDisclosureRow(label: label, arguments: toolCall.arguments)
            }
        }
        .padding(.bottom, 5)
    }

    private struct ToolCallDisclosureRow: View {
        let label: String
        let arguments: String
        @State private var isExpanded = true

        private var trimmedArguments: String {
            arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                if trimmedArguments.isEmpty {
                    toolHeader
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        toolHeader
                    }
                    .buttonStyle(.plain)
                }

                if !trimmedArguments.isEmpty, isExpanded {
                    CappedScrollableText(
                        text: trimmedArguments,
                        maxHeight: 120,
                        font: .caption2,
                        foreground: .secondary
                    )
                }
            }
            .padding(.leading, 4)
        }

        private var toolHeader: some View {
            HStack(spacing: 4) {
                Text("调用：\(label)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !trimmedArguments.isEmpty {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func toolPermissionInlineView(onDecision: @escaping (ToolPermissionDecision) -> Void) -> some View {
        ToolPermissionInlineView(onDecision: onDecision)
            .padding(.bottom, 5)
    }

    @ViewBuilder
    private func toolResultsDisclosureView(
        _ toolCalls: [InternalToolCall],
        resultText: String,
        isPending: Bool
    ) -> some View {
        let toolNames = toolCalls.map { toolDisplayLabel(for: $0.toolName) }
        VStack(alignment: .leading, spacing: 5) {
            if isPending {
                HStack {
                    ShimmeringText(
                        text: "结果：\(toolNames.joined(separator: ", "))",
                        font: .footnote,
                        baseColor: .secondary,
                        highlightColor: .primary.opacity(0.85)
                    )
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .foregroundColor(.secondary)
            } else {
                Button(action: {
                    withAnimation {
                        isToolCallsExpanded.toggle()
                    }
                }) {
                    HStack {
                        Text("结果：\(toolNames.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: isToolCallsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isToolCallsExpanded && !isPending {
                ForEach(toolCalls, id: \.id) { toolCall in
                    let result = (toolCall.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = toolDisplayLabel(for: toolCall.toolName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                        if !result.isEmpty {
                            CappedScrollableText(
                                text: result,
                                maxHeight: 120,
                                font: .caption2,
                                foreground: .secondary
                            )
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.bottom, 5)
    }

    private struct ShimmeringText: View {
        let text: String
        let font: Font
        let baseColor: Color
        let highlightColor: Color
        var duration: Double = 1.6
        var angle: Double = 18
        var bandWidthRatio: CGFloat = 0.7
        var bandHeightRatio: CGFloat = 1.6

        @State private var isAnimating = false

        var body: some View {
            Text(text)
                .font(font)
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
                            .font(font)
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

    private struct ToolPermissionInlineView: View {
        let onDecision: (ToolPermissionDecision) -> Void
        @State private var isShowingMoreOptions = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button("允许") {
                        onDecision(.allowOnce)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingMoreOptions.toggle()
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
                    .buttonStyle(.bordered)
                }

                if isShowingMoreOptions {
                    HStack(spacing: 6) {
                        Button("拒绝", role: .destructive) {
                            onDecision(.deny)
                        }
                        .buttonStyle(.bordered)

                        Button("补充提示") {
                            onDecision(.supplement)
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 6) {
                        Button("保持允许") {
                            onDecision(.allowForTool)
                        }
                        .buttonStyle(.bordered)

                        Button("完全权限") {
                            onDecision(.allowAll)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.mini)
        }
    }

    private struct CappedScrollableText: View {
        let text: String
        let maxHeight: CGFloat
        let font: Font
        let foreground: Color
        @State private var measuredHeight: CGFloat = 0

        var body: some View {
            ScrollView {
                Text(text)
                    .font(font)
                    .foregroundColor(foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    private struct TextHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
    
    // MARK: - 回退样式
    
    @ViewBuilder
    private func userBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.blue.opacity(0.7) : Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private func errorBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.red.opacity(0.7) : Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private func assistantBubbleFallback<Content: View>(_ content: Content, isError: Bool = false) -> some View {
        content
            .background(isError ? Color.red.opacity(0.7) : (enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)))
            .clipShape(assistantBubbleShape)
    }

    @ViewBuilder
    private func assistantBubbleContainer<Content: View>(_ content: Content, isError: Bool) -> some View {
        let sizedContent = content
            .frame(width: shouldForceMergedWidth ? bubbleMaxWidth : nil, alignment: .leading)
        
        Group {
            if enableLiquidGlass {
                if #available(watchOS 26.0, *) {
                    sizedContent
                        .glassEffect(.clear, in: assistantBubbleShape)
                        .background(isError ? Color.red.opacity(0.5) : nil)
                } else {
                    assistantBubbleFallback(sizedContent, isError: isError)
                }
            } else {
                assistantBubbleFallback(sizedContent, isError: isError)
            }
        }
        .overlay(alignment: .top) {
            if shouldShowMergedSeparator {
                separatorLine
            }
        }
        .clipShape(assistantBubbleShape)
    }
}

// MARK: - 思考提示相关

private extension ChatBubble {
    
    var shouldShowThinkingIndicator: Bool {
        message.role == .assistant
            && message.content.isEmpty
            && (message.reasoningContent ?? "").isEmpty
            && (message.toolCalls ?? []).isEmpty
    }
    
    var currentThinkingText: String {
        guard shouldShowThinkingIndicator else { return "" }
        return "正在思考..."
    }
}

private struct AttachmentImageView: View {
    let fileName: String
    let height: CGFloat
    let onPreview: (UIImage) -> Void

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Button {
                    onPreview(image)
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: height)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Text(NSLocalizedString("图片丢失", comment: ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    )
            }
        }
        .task {
            if image == nil {
                await loadImage()
            }
        }
    }

    private func loadImage() async {
        guard let data = Persistence.loadImage(fileName: fileName),
              let uiImage = UIImage(data: data) else {
            return
        }
        await MainActor.run {
            image = uiImage
        }
    }
}

private struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Watch Audio Player Manager

class WatchAudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentFileName: String?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    
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
            // 使用 .ambient 类别，会遵循系统静音设置
            // 静音模式下不会发出声音，避免尴尬
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            duration = audioPlayer?.duration ?? 0
            currentTime = 0
            
            audioPlayer?.play()
            
            currentFileName = fileName
            isPlaying = true
            
            startProgressTimer()
        } catch {
            #if DEBUG
            print(
                String(
                    format: NSLocalizedString("播放音频失败: %@", comment: ""),
                    error.localizedDescription
                )
            )
            #endif
        }
    }
    
    func stop() {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
    }
    
    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            DispatchQueue.main.async {
                self.currentTime = player.currentTime
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.stopProgressTimer()
            self.isPlaying = false
            self.currentTime = self.duration
        }
    }
    
    deinit {
        stop()
    }
}
