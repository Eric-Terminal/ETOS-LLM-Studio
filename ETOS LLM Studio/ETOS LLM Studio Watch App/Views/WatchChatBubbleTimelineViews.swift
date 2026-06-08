// ============================================================================
// WatchChatBubbleTimelineViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡的思考时间线与工具状态辅助视图。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchAssistantTimelineStepShell<Content: View>: View {
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
    private let content: Content

    init(
        iconName: String,
        iconColor: Color,
        lineColor: Color,
        iconSize: CGFloat = 12,
        iconFrameSize: CGFloat = 18,
        iconColumnWidth: CGFloat = 20,
        contentSpacing: CGFloat = 6,
        iconTopPadding: CGFloat = 6,
        contentVerticalPadding: CGFloat = 6,
        lineTopY: CGFloat = 7,
        lineBottomY: CGFloat = 23,
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
            WatchAssistantTimelineLineShape(
                isFirst: isFirst,
                isLast: isLast,
                extendsLineThroughContent: extendsLineThroughContent,
                lineTopExtension: lineTopExtension,
                lineBottomExtension: lineBottomExtension,
                iconTopY: lineTopY,
                iconBottomY: lineBottomY
            )
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .frame(width: iconColumnWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchAssistantTimelineLineShape: Shape {
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

private enum WatchReasoningPreviewScrollTarget {
    case bottom
}

struct WatchReasoningPreviewContent<Content: View>: View {
    let isPreviewing: Bool
    let maxHeight: CGFloat
    let contentID: String
    private let content: Content

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
                            .id(WatchReasoningPreviewScrollTarget.bottom)
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

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(WatchReasoningPreviewScrollTarget.bottom, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(WatchReasoningPreviewScrollTarget.bottom, anchor: .bottom)
            }
        }
    }
}

struct WatchReasoningMarkdownContentView: View {
    let reasoning: String
    let preparedReasoningContent: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let textColor: Color
    let font: Font
    let onCodeBlockHeaderTap: ((String) -> Void)?

    var body: some View {
        if enableMarkdown,
           let preparedReasoningContent,
           preparedReasoningContent.sourceText == reasoning {
            ETAdvancedMarkdownRenderer(
                content: reasoning,
                preparedContent: preparedReasoningContent,
                enableMarkdown: true,
                isOutgoing: false,
                enableAdvancedRenderer: enableAdvancedRenderer,
                enableMathRendering: enableMathRendering,
                customTextColor: textColor,
                onCodeBlockHeaderTap: onCodeBlockHeaderTap
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(reasoning)
                .etFont(font, sampleText: reasoning)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WatchTimelineReasoningStepView: View {
    let reasoning: String
    let preparedReasoningContent: ETPreparedMarkdownRenderPayload?
    @Binding var isExpanded: Bool
    let isPreviewing: Bool
    let suppressContentRender: Bool
    let isShimmering: Bool
    let customTextColor: Color?
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let reasoningStartedAt: Date?
    let reasoningCompletedAt: Date?
    let fallbackReasoningDuration: TimeInterval?
    let reasoningSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isPreviewing {
                        isExpanded = true
                    } else {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    headerTitleView
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Image(systemName: isFullyExpanded ? "chevron.down" : "chevron.right")
                        .etFont(.caption2.weight(.semibold))
                        .foregroundStyle(secondaryColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if shouldShowContent {
                WatchReasoningPreviewContent(
                    isPreviewing: isPreviewing,
                    maxHeight: 64.5,
                    contentID: reasoning
                ) {
                    WatchReasoningMarkdownContentView(
                        reasoning: reasoning,
                        preparedReasoningContent: preparedReasoningContent,
                        enableMarkdown: enableMarkdown,
                        enableAdvancedRenderer: enableAdvancedRenderer,
                        enableMathRendering: enableMathRendering,
                        textColor: secondaryColor,
                        font: .footnote,
                        onCodeBlockHeaderTap: nil
                    )
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isFullyExpanded)
        .animation(.easeInOut(duration: 0.2), value: isPreviewing)
    }

    private var isFullyExpanded: Bool {
        isExpanded && !isPreviewing && !suppressContentRender
    }

    private var shouldShowContent: Bool {
        !suppressContentRender && (isExpanded || isPreviewing)
    }

    private var titleColor: Color {
        customTextColor?.opacity(0.9) ?? .primary.opacity(0.84)
    }

    private var secondaryColor: Color {
        customTextColor?.opacity(0.76) ?? .secondary.opacity(0.9)
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
                font: .footnote.weight(.semibold),
                baseColor: secondaryColor,
                highlightColor: titleColor
            )
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(title)
                .etFont(.footnote.weight(.semibold))
                .foregroundStyle(titleColor)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reasoningHeaderTitle(referenceDate: Date) -> String {
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

        guard let reasoningSummary,
              !reasoningSummary.isEmpty else {
            return baseTitle
        }
        return String(format: NSLocalizedString("%@：%@", comment: ""), baseTitle, reasoningSummary)
    }

    private func reasoningElapsedSeconds(referenceDate: Date) -> Int? {
        let elapsed: TimeInterval
        if let reasoningStartedAt {
            let finishedAt = reasoningCompletedAt ?? referenceDate
            elapsed = max(0, finishedAt.timeIntervalSince(reasoningStartedAt))
        } else if let fallbackReasoningDuration {
            elapsed = max(0, fallbackReasoningDuration)
        } else {
            return nil
        }
        if elapsed == 0 {
            return 0
        }
        return max(1, Int(elapsed.rounded(.down)))
    }
}

struct WatchTimelineToolCallStepContent: View {
    let label: String
    let statusTitle: String
    let statusIconName: String
    let statusColor: Color
    let showPendingGuidance: Bool
    let customTextColor: Color?

    private var titleText: String {
        "\(NSLocalizedString("调用工具", comment: "Tool call timeline title"))：\(label)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 4) {
                if showPendingGuidance {
                    WatchToolCallPendingGuidanceLabel(text: titleText, color: titleColor)
                } else {
                    Text(titleText)
                        .etFont(.footnote.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .etFont(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3) {
                Image(systemName: statusIconName)
                    .etFont(.system(size: 9, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .etFont(.caption2)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }

        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleColor: Color {
        customTextColor?.opacity(0.9) ?? .primary.opacity(0.84)
    }

    private var secondaryColor: Color {
        customTextColor?.opacity(0.74) ?? .secondary.opacity(0.88)
    }
}

struct WatchToolCallSummaryBubbleRow: View {
    let label: String
    let statusTitle: String
    let statusIconName: String
    let statusColor: Color
    let showPendingGuidance: Bool
    let customTextColor: Color?

    private var titleColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.9)
        }
        return .primary
    }

    private var subtitleColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                if showPendingGuidance {
                    WatchToolCallPendingGuidanceLabel(text: label, color: titleColor)
                } else {
                    Text(label)
                        .etFont(.footnote.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                }

                HStack(spacing: 3) {
                    Image(systemName: statusIconName)
                        .etFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(statusTitle)
                        .etFont(.caption2)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .etFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(subtitleColor)
        }
        .contentShape(Rectangle())
    }
}

struct WatchToolCallPendingGuidanceLabel: View {
    let text: String
    let color: Color
    @State private var shimmerAnimating = false
    @State private var bounce = false

    var body: some View {
        Text(text)
            .etFont(.footnote.weight(.semibold))
            .foregroundStyle(color.opacity(0.75))
            .lineLimit(1)
            .overlay(
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let bandWidth = max(1, width * 0.7)
                    let startX = -bandWidth
                    let endX = width + bandWidth
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: color, location: 0.35),
                                    .init(color: color, location: 0.65),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: bandWidth, height: max(1, height * 1.5))
                        .rotationEffect(.degrees(16))
                        .position(x: shimmerAnimating ? endX : startX, y: height / 2)
                        .blendMode(.screen)
                }
                .mask(
                    Text(text)
                        .etFont(.footnote.weight(.semibold))
                )
                .allowsHitTesting(false)
            )
            .offset(y: bounce ? -1.2 : 1.2)
            .onAppear {
                guard !shimmerAnimating else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerAnimating = true
                }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    bounce = true
                }
            }
    }
}
