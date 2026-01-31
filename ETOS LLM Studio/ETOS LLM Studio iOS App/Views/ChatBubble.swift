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
    let message: ChatMessage
    @Binding var isReasoningExpanded: Bool
    @Binding var isToolCallsExpanded: Bool
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var imagePreview: ImagePreviewPayload?
    @State private var availableWidth: CGFloat = 0
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    
    // Telegram 颜色
    private let telegramBlue = Color(red: 0.24, green: 0.56, blue: 0.95)
    private let telegramBlueDark = Color(red: 0.17, green: 0.45, blue: 0.82)
    
    private var isOutgoing: Bool {
        message.role == .user
    }
    
    private var isError: Bool {
        message.role == .error || (message.role == .assistant && message.content.hasPrefix("重试失败"))
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
        mergeWithPrevious && !isOutgoing
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
        if mergeWithPrevious && mergeWithNext {
            return (Color.black.opacity(0.04), 1, 0)
        }
        return (Color.black.opacity(0.08), 3, 1)
    }

    private var bubbleMaxWidth: CGFloat {
        let baseWidth = availableWidth > 0 ? availableWidth : UIScreen.main.bounds.width
        return baseWidth * 0.88
    }

    private var shouldForceMergedWidth: Bool {
        !isOutgoing && (mergeWithPrevious || mergeWithNext)
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
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // 用户消息靠右：左边放 Spacer
            if isOutgoing {
                Spacer(minLength: 20)
            }
            
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                // 图片附件 - 作为气泡显示
                if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                    imageAttachmentsView(fileNames: imageFileNames)
                }

                // 文件附件 - 作为气泡显示
                if let fileFileNames = message.fileFileNames, !fileFileNames.isEmpty {
                    fileAttachmentsView(fileNames: fileFileNames)
                }
                
                // 气泡内容（仅当有非图片内容时显示）
                if shouldShowTextBubble {
                    VStack(alignment: .leading, spacing: 6) {
                        textContentStack
                        
                        // 版本指示器（Telegram 风格：右下角）
                        if message.hasMultipleVersions {
                            HStack(spacing: 6) {
                                compactVersionIndicator
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: shouldForceMergedWidth ? bubbleMaxWidth : nil, alignment: .leading)
                    .background(bubbleDecoratedBackground)
                    .shadow(color: bubbleShadow.color, radius: bubbleShadow.radius, y: bubbleShadow.y)
                }
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: isOutgoing ? .trailing : .leading)
            
            // AI 消息靠左：右边放 Spacer
            if !isOutgoing {
                Spacer(minLength: 20)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, mergeWithPrevious ? 0 : 3)
        .padding(.bottom, mergeWithNext ? 0 : 3)
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
    }

    private struct RowWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
    
    // MARK: - 紧凑版本指示器 (Telegram 风格)
    
    @ViewBuilder
    private var compactVersionIndicator: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.switchToPreviousVersion(of: message)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(message.getCurrentVersionIndex() == 0)
            .opacity(message.getCurrentVersionIndex() > 0 ? 1 : 0.4)
            
            Text("\(message.getCurrentVersionIndex() + 1)/\(message.getAllVersions().count)")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
            
            Button {
                viewModel.switchToNextVersion(of: message)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(message.getCurrentVersionIndex() >= message.getAllVersions().count - 1)
            .opacity(message.getCurrentVersionIndex() < message.getAllVersions().count - 1 ? 1 : 0.4)
        }
        .foregroundStyle(isOutgoing ? Color.white.opacity(0.8) : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
        )
    }
    
    // MARK: - 气泡渐变背景
    
    private var bubbleGradient: some ShapeStyle {
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
                    colors: [telegramBlue.opacity(userOpacity), telegramBlueDark.opacity(userOpacity)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .assistant, .system, .tool:
            // 接收消息：浅灰/白色
            let baseColor = enableBackground
                ? Color(uiColor: .secondarySystemBackground).opacity(assistantOpacity)
                : Color(uiColor: .systemBackground)
            return AnyShapeStyle(baseColor)
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.15 * errorOpacity))
        @unknown default:
            return AnyShapeStyle(Color(UIColor.secondarySystemBackground))
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if enableLiquidGlass {
            if #available(iOS 26.0, *) {
                bubbleShape
                    .fill(bubbleGradient)
                    .glassEffect(.clear, in: bubbleShape)
                    .clipShape(bubbleShape)
            } else {
                bubbleShape
                    .fill(bubbleGradient)
            }
        } else {
            bubbleShape
                .fill(bubbleGradient)
        }
    }

    private var bubbleDecoratedBackground: some View {
        ZStack(alignment: .top) {
            bubbleBackground
            if shouldShowMergedSeparator {
                Rectangle()
                    .fill(separatorColor)
                    .frame(height: separatorThickness)
            }
        }
        .clipShape(bubbleShape)
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var textContentStack: some View {
        // 思考过程 (Telegram 风格折叠)
        if let reasoning = message.reasoningContent,
           !reasoning.isEmpty {
            ReasoningDisclosureView(
                reasoning: reasoning,
                isExpanded: $isReasoningExpanded,
                isOutgoing: isOutgoing,
                isShimmering: shouldShimmerReasoningHeader
            )
        }
        
        // 工具调用/结果（折叠展示）
        if let toolCalls = message.toolCalls,
           !toolCalls.isEmpty {
            ToolCallsInlineView(
                toolCalls: toolCalls,
                isOutgoing: isOutgoing
            )
            if activeToolPermissionRequest != nil {
                ToolPermissionInlineView(onDecision: { decision in
                    toolPermissionCenter.resolveActiveRequest(with: decision)
                })
            }
            let shouldShowResults = hasToolResults || hasPendingToolResults
            if shouldShowResults {
                ToolResultsDisclosureView(
                    toolCalls: toolCalls,
                    resultText: message.role == .tool ? message.content : "",
                    isExpanded: $isToolCallsExpanded,
                    isOutgoing: isOutgoing,
                    isPending: hasPendingToolResults
                )
            }
        }
        
        // 消息正文
        if !message.content.isEmpty, message.role != .tool || (message.toolCalls?.isEmpty ?? true) {
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName)
            } else {
                renderContent(message.content)
                    .font(.body)
                    .foregroundStyle(isOutgoing ? Color.white : Color.primary)
                    .textSelection(.enabled)
            }
        } else if message.role == .assistant,
                  (message.reasoningContent ?? "").isEmpty,
                  (message.toolCalls ?? []).isEmpty {
            // 加载指示器
            if viewModel.isSendingMessage {
                ShimmeringText(
                    text: "正在思考...",
                    font: .subheadline,
                    baseColor: Color.secondary,
                    highlightColor: Color.primary.opacity(0.85)
                )
            } else {
                Text("正在思考...")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
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
            
            LazyVGrid(columns: columns, alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                ForEach(fileNames, id: \.self) { fileName in
                    if let image = loadImage(fileName: fileName) {
                        Button {
                            imagePreview = ImagePreviewPayload(image: image)
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(
                                    minWidth: fileNames.count == 1 ? 150 : 80,
                                    maxWidth: fileNames.count == 1 ? 220 : 140
                                )
                                .frame(height: fileNames.count == 1 ? 180 : 100)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: fileNames.count == 1 ? 180 : 100)
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                    Text("图片丢失")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            )
                            .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.85) : Color.secondary)
                    Text(fileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isOutgoing ? Color.white : Color.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isOutgoing ? telegramBlueDark : Color(uiColor: .secondarySystemBackground))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
    
    private func loadImage(fileName: String) -> UIImage? {
        guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
        return UIImage(data: data)
    }
    
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        if enableMarkdown {
            Markdown(content)
                .markdownSoftBreakMode(.lineBreak)
                .markdownTextStyle {
                    ForegroundColor(isOutgoing ? .white : .primary)
                }
        } else {
            Text(content)
        }
    }
    
    @ViewBuilder
    private func audioPlayerView(fileName: String) -> some View {
        let foregroundColor = isOutgoing ? Color.white : Color.primary
        let secondaryColor = isOutgoing ? Color.white.opacity(0.7) : Color.secondary
        
        HStack(spacing: 12) {
            // 播放按钮
            Button {
                audioPlayer.togglePlayback(fileName: fileName)
            } label: {
                ZStack {
                    Circle()
                        .fill(isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
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
                        .font(.caption2)
                        .foregroundStyle(secondaryColor)
                        .monospacedDigit()
                } else {
                    Text(fileName)
                        .font(.caption2)
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

// MARK: - Audio Player Manager

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
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

// MARK: - 思考过程折叠视图（性能优化）

/// 独立的思考过程视图，避免长文本导致父视图重复布局
/// 使用 Equatable 优化：只有在 reasoning 或 isExpanded 变化时才重新渲染
struct ReasoningDisclosureView: View, Equatable {
    let reasoning: String
    @Binding var isExpanded: Bool
    let isOutgoing: Bool
    let isShimmering: Bool
    
    // 限制显示的最大字符数，超过时截断并提示
    private static let maxDisplayLength = 8000
    
    static func == (lhs: ReasoningDisclosureView, rhs: ReasoningDisclosureView) -> Bool {
        lhs.reasoning == rhs.reasoning
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.isShimmering == rhs.isShimmering
    }
    
    private var displayText: String {
        if reasoning.count > Self.maxDisplayLength {
            return String(reasoning.prefix(Self.maxDisplayLength)) + "\n\n... (内容过长，已截断)"
        }
        return reasoning
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let baseColor = isOutgoing ? Color.white.opacity(0.9) : Color.secondary
            let highlightColor = isOutgoing ? Color.white : Color.primary.opacity(0.85)
            // 点击区域：标题行
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12))
                        .foregroundStyle(baseColor)
                    if isShimmering {
                        ShimmeringText(
                            text: "思考过程",
                            font: .subheadline.weight(.medium),
                            baseColor: baseColor,
                            highlightColor: highlightColor
                        )
                        .lineLimit(1)
                    } else {
                        Text("思考过程")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(baseColor)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(baseColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // 内容区域：只在展开时渲染
            if isExpanded {
                Text(displayText)
                    .font(.subheadline)
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.85) : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

// MARK: - 工具调用视图（内联展示）
struct ToolCallsInlineView: View, Equatable {
    let toolCalls: [InternalToolCall]
    let isOutgoing: Bool
    
    static func == (lhs: ToolCallsInlineView, rhs: ToolCallsInlineView) -> Bool {
        lhs.toolCalls.map(\.id) == rhs.toolCalls.map(\.id) && lhs.isOutgoing == rhs.isOutgoing
    }

    private func displayName(for toolName: String) -> String {
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        return MCPManager.shared.displayLabel(for: toolName) ?? toolName
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(toolCalls, id: \.id) { call in
                let label = displayName(for: call.toolName)
                ToolCallDisclosureRow(
                    label: label,
                    arguments: call.arguments,
                    isOutgoing: isOutgoing
                )
            }
        }
    }

    private struct ToolCallDisclosureRow: View {
        let label: String
        let arguments: String
        let isOutgoing: Bool
        @State private var isExpanded = true

        private var trimmedArguments: String {
            arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
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
                        maxHeight: 200,
                        font: .caption,
                        foreground: isOutgoing ? Color.white.opacity(0.7) : Color.secondary,
                        enableSelection: true
                    )
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isOutgoing ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
                }
            }
        }

        private var toolHeader: some View {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12))
                Text("调用：\(label)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !trimmedArguments.isEmpty {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : Color.secondary)
            .contentShape(Rectangle())
        }
    }
}

private struct ToolPermissionInlineView: View {
    let onDecision: (ToolPermissionDecision) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("允许") {
                onDecision(.allowOnce)
            }
            .buttonStyle(.borderedProminent)

            Menu {
                Button("拒绝", role: .destructive) {
                    onDecision(.deny)
                }
                Button("补充提示") {
                    onDecision(.supplement)
                }
                Button("保持允许") {
                    onDecision(.allowForTool)
                }
                Button("完全权限") {
                    onDecision(.allowAll)
                }
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .buttonStyle(.bordered)
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
    
    static func == (lhs: ToolResultsDisclosureView, rhs: ToolResultsDisclosureView) -> Bool {
        lhs.toolCalls.map(\.id) == rhs.toolCalls.map(\.id)
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.resultText == rhs.resultText
            && lhs.isPending == rhs.isPending
    }

    private func displayName(for toolName: String) -> String {
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        return MCPManager.shared.displayLabel(for: toolName) ?? toolName
    }
    
    var body: some View {
        let toolNames = toolCalls.map { displayName(for: $0.toolName) }
        VStack(alignment: .leading, spacing: 0) {
            if isPending {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                    ShimmeringText(
                        text: "结果：\(toolNames.joined(separator: ", "))",
                        font: .subheadline.weight(.medium),
                        baseColor: isOutgoing ? Color.white.opacity(0.9) : Color.secondary,
                        highlightColor: isOutgoing ? Color.white : Color.primary.opacity(0.85)
                    )
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.4) : Color.secondary.opacity(0.6))
                }
                .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : Color.secondary)
                .contentShape(Rectangle())
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12))
                        Text("结果：\(toolNames.joined(separator: ", "))")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded && !isPending {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls, id: \.id) { call in
                        let result = (call.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
                        let label = displayName(for: call.toolName)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label)
                                .font(.caption.weight(.semibold))
                            if !result.isEmpty {
                                CappedScrollableText(
                                    text: result,
                                    maxHeight: 200,
                                    font: .caption,
                                    foreground: isOutgoing ? Color.white.opacity(0.7) : Color.secondary,
                                    enableSelection: true
                                )
                            }
                        }
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.7) : Color.secondary)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isOutgoing ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1))
                        )
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
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
                .font(font)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(font)
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
