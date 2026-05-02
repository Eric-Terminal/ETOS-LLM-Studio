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


struct BubbleCornerShape: Shape {
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


// MARK: - Telegram 输入指示器动画

struct TelegramTypingIndicator: View {
    @State var animationPhase = 0
    
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
    
    let barCount = 28
    let heights: [CGFloat] = (0..<28).map { _ in CGFloat.random(in: 0.3...1.0) }
    
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


struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}


struct ChatBubbleOpenMoreGestureModifier: ViewModifier {
    let onOpenMore: (() -> Void)?

    func body(content: Content) -> some View {
        if let onOpenMore {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            onOpenMore()
                        }
                )
        } else {
            content
        }
    }
}


enum ChatAttachmentImageCache {
    static let cache: NSCache<NSString, UIImage> = {
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


struct AttachmentImageView: View {
    let fileName: String
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let onPreview: (UIImage) -> Void

    @State var image: UIImage?
    @State var didAttemptLoad = false

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
                            Text(NSLocalizedString("图片丢失", comment: ""))
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

    func loadImage() async {
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


// MARK: - 思考与工具时间线

struct AssistantTimelineStepShell<Content: View>: View {
    let iconName: String
    let iconColor: Color
    let lineColor: Color
    let iconSize: CGFloat
    let iconFrameSize: CGFloat
    let iconColumnWidth: CGFloat
    let contentSpacing: CGFloat
    let iconTopPadding: CGFloat
    let contentVerticalPadding: CGFloat
    let lineTopY: CGFloat
    let lineBottomY: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let extendsLineThroughContent: Bool
    let lineTopExtension: CGFloat
    let lineBottomExtension: CGFloat
    let content: Content

    init(
        iconName: String,
        iconColor: Color,
        lineColor: Color,
        iconSize: CGFloat = 14,
        iconFrameSize: CGFloat = 22,
        iconColumnWidth: CGFloat = 24,
        contentSpacing: CGFloat = 8,
        iconTopPadding: CGFloat = 7,
        contentVerticalPadding: CGFloat = 7,
        lineTopY: CGFloat = 8,
        lineBottomY: CGFloat = 28,
        isFirst: Bool,
        isLast: Bool,
        extendsLineThroughContent: Bool = false,
        lineTopExtension: CGFloat = 0,
        lineBottomExtension: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.lineColor = lineColor
        self.iconSize = iconSize
        self.iconFrameSize = iconFrameSize
        self.iconColumnWidth = iconColumnWidth
        self.contentSpacing = contentSpacing
        self.iconTopPadding = iconTopPadding
        self.contentVerticalPadding = contentVerticalPadding
        self.lineTopY = lineTopY
        self.lineBottomY = lineBottomY
        self.isFirst = isFirst
        self.isLast = isLast
        self.extendsLineThroughContent = extendsLineThroughContent
        self.lineTopExtension = lineTopExtension
        self.lineBottomExtension = lineBottomExtension
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: contentSpacing) {
            Image(systemName: iconName)
                .etFont(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: iconFrameSize, height: iconFrameSize)
                .padding(.top, iconTopPadding)
                .frame(width: iconColumnWidth)

            content
                .padding(.vertical, contentVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            AssistantTimelineLineShape(
                isFirst: isFirst,
                isLast: isLast,
                extendsLineThroughContent: extendsLineThroughContent,
                lineTopExtension: lineTopExtension,
                lineBottomExtension: lineBottomExtension,
                iconTopY: lineTopY,
                iconBottomY: lineBottomY
            )
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: iconColumnWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct AssistantTimelineLineShape: Shape {
    let isFirst: Bool
    let isLast: Bool
    let extendsLineThroughContent: Bool
    let lineTopExtension: CGFloat
    let lineBottomExtension: CGFloat
    let iconTopY: CGFloat
    let iconBottomY: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.midX
        if !isFirst {
            path.move(to: CGPoint(x: x, y: rect.minY - lineTopExtension))
            path.addLine(to: CGPoint(x: x, y: rect.minY + iconTopY))
        }
        if extendsLineThroughContent || !isLast {
            path.move(to: CGPoint(x: x, y: rect.minY + iconBottomY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + lineBottomExtension))
        }
        return path
    }
}


struct TimelineReasoningStepView: View {
    let reasoning: String
    let preparedReasoningContent: ETPreparedMarkdownRenderPayload?
    @Binding var isExpanded: Bool
    let isPreviewing: Bool
    let isShimmering: Bool
    let customTextColor: Color?
    let usesNoBubbleStyle: Bool
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let reasoningStartedAt: Date?
    let reasoningCompletedAt: Date?
    let reasoningSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isPreviewing {
                        isExpanded = true
                    } else {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    headerTitleView
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .etFont(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isFullyExpanded ? 90 : 0))
                        .foregroundStyle(secondaryColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if shouldShowContent {
                ReasoningPreviewContent(
                    isPreviewing: isPreviewing,
                    maxHeight: 118,
                    contentID: reasoning
                ) {
                    ReasoningMarkdownContentView(
                        reasoning: reasoning,
                        preparedReasoningContent: preparedReasoningContent,
                        enableMarkdown: enableMarkdown,
                        enableAdvancedRenderer: enableAdvancedRenderer,
                        enableMathRendering: enableMathRendering,
                        isOutgoing: false,
                        textColor: secondaryColor,
                        font: .subheadline
                    )
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isFullyExpanded)
        .animation(.easeInOut(duration: 0.2), value: isPreviewing)
    }

    var isFullyExpanded: Bool {
        isExpanded && !isPreviewing
    }

    var shouldShowContent: Bool {
        isExpanded || isPreviewing
    }

    var titleColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.92)
        }
        return usesNoBubbleStyle ? .primary.opacity(0.88) : .primary.opacity(0.82)
    }

    var secondaryColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return .secondary.opacity(0.92)
    }

    @ViewBuilder
    var headerTitleView: some View {
        if let reasoningStartedAt, reasoningCompletedAt == nil {
            TimelineView(.periodic(from: reasoningStartedAt, by: 1)) { context in
                headerTitleLabel(title: reasoningHeaderTitle(referenceDate: context.date))
            }
        } else {
            headerTitleLabel(title: reasoningHeaderTitle(referenceDate: reasoningCompletedAt ?? Date()))
        }
    }

    @ViewBuilder
    func headerTitleLabel(title: String) -> some View {
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

    func reasoningHeaderTitle(referenceDate: Date) -> String {
        if isPreviewing,
           reasoningCompletedAt == nil,
           let thinkingTitle = preparedReasoningContent?.thinkingTitle,
           !thinkingTitle.isEmpty {
            return thinkingTitle
        }

        let baseTitle: String
        if let elapsedSeconds = reasoningElapsedSeconds(referenceDate: referenceDate) {
            baseTitle = String(format: NSLocalizedString("已经思考%d秒", comment: ""), elapsedSeconds)
        } else {
            baseTitle = NSLocalizedString("思考过程", comment: "")
        }

        guard let summary = reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return baseTitle
        }
        return String(format: NSLocalizedString("%@：%@", comment: ""), baseTitle, summary)
    }

    func reasoningElapsedSeconds(referenceDate: Date) -> Int? {
        guard let reasoningStartedAt else { return nil }
        let finishedAt = reasoningCompletedAt ?? referenceDate
        let elapsed = max(0, finishedAt.timeIntervalSince(reasoningStartedAt))
        if elapsed == 0 {
            return 0
        }
        return max(1, Int(elapsed.rounded(.down)))
    }
}


struct TimelineToolCallStepContent: View {
    let label: String
    let statusTitle: String
    let statusIconName: String
    let statusColor: Color
    let showPendingGuidance: Bool
    let customTextColor: Color?

    var titleText: String {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: statusIconName)
                    .etFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .etFont(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }

        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var titleColor: Color {
        customTextColor?.opacity(0.92) ?? .primary.opacity(0.82)
    }

    var secondaryColor: Color {
        customTextColor?.opacity(0.76) ?? .secondary.opacity(0.9)
    }
}


enum ReasoningPreviewScrollTarget {
    case bottom
}


struct ReasoningPreviewContent<Content: View>: View {
    let isPreviewing: Bool
    let maxHeight: CGFloat
    let contentID: String
    let content: Content

    init(
        isPreviewing: Bool,
        maxHeight: CGFloat,
        contentID: String,
        @ViewBuilder content: () -> Content
    ) {
        self.isPreviewing = isPreviewing
        self.maxHeight = maxHeight
        self.contentID = contentID
        self.content = content()
    }

    var body: some View {
        if isPreviewing {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                        Color.clear
                            .frame(height: 1)
                            .id(ReasoningPreviewScrollTarget.bottom)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 0.84),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onAppear {
                    scrollToBottom(with: proxy, animated: false)
                }
                .onChange(of: contentID) {
                    scrollToBottom(with: proxy, animated: true)
                }
            }
        } else {
            content
        }
    }

    func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(ReasoningPreviewScrollTarget.bottom, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(ReasoningPreviewScrollTarget.bottom, anchor: .bottom)
            }
        }
    }
}


struct ReasoningMarkdownContentView: View {
    let reasoning: String
    let preparedReasoningContent: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let isOutgoing: Bool
    let textColor: Color
    let font: Font

    var body: some View {
        if enableMarkdown,
           let preparedReasoningContent,
           preparedReasoningContent.sourceText == reasoning {
            ETAdvancedMarkdownRenderer(
                content: reasoning,
                preparedContent: preparedReasoningContent,
                enableMarkdown: true,
                isOutgoing: isOutgoing,
                enableAdvancedRenderer: enableAdvancedRenderer,
                enableMathRendering: enableMathRendering,
                customTextColor: textColor
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(reasoning)
                .etFont(font, sampleText: reasoning)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


struct ToolCallPendingGuidanceLabel: View {
    let text: String
    let color: Color
    @State var shouldBounce = false

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


struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
