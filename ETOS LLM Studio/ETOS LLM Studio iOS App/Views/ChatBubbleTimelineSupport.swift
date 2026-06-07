// ============================================================================
// ChatBubbleTimelineSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的思考过程与工具时间线相关辅助视图。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

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
    private let content: Content

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

    private var isFullyExpanded: Bool {
        isExpanded && !isPreviewing
    }

    private var shouldShowContent: Bool {
        isExpanded || isPreviewing
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

    private func reasoningElapsedSeconds(referenceDate: Date) -> Int? {
        guard let reasoningStartedAt else { return nil }
        let finishedAt = reasoningCompletedAt ?? referenceDate
        let elapsed = max(0, finishedAt.timeIntervalSince(reasoningStartedAt))
        if elapsed == 0 {
            return 0
        }
        return max(1, Int(elapsed.rounded(.down)))
    }
}

struct ToolCallSummaryBubbleRow: View {
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

struct TimelineToolCallStepContent: View {
    let label: String
    let statusTitle: String
    let statusIconName: String
    let statusColor: Color
    let showPendingGuidance: Bool
    let customTextColor: Color?

    private var titleText: String {
        "\(NSLocalizedString("调用工具", comment: "Tool call timeline title"))：\(label)"
    }

    private var titleColor: Color {
        customTextColor?.opacity(0.9) ?? .primary.opacity(0.84)
    }

    private var secondaryColor: Color {
        customTextColor?.opacity(0.74) ?? .secondary.opacity(0.88)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
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
                    .etFont(.caption.weight(.semibold))
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
}

struct ToolCallPendingGuidanceLabel: View {
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
