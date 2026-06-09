// ============================================================================
// ChatBubbleReasoningViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天气泡中的思考过程预览、展开视图与 reasoning 文案辅助。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

private enum ReasoningPreviewScrollTarget {
    case bottom
}

struct ReasoningPreviewContent<Content: View>: View {
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

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
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

struct ReasoningDisclosureView: View, Equatable {
    let reasoning: String
    let preparedReasoningContent: ETPreparedMarkdownRenderPayload?
    @Binding var isExpanded: Bool
    let isPreviewing: Bool
    let suppressContentRender: Bool
    let isOutgoing: Bool
    let usesNoBubbleStyle: Bool
    let isShimmering: Bool
    let customTextColor: Color?
    let previewMaxHeight: CGFloat
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let reasoningStartedAt: Date?
    let reasoningCompletedAt: Date?
    let reasoningSummary: String?

    static func == (lhs: ReasoningDisclosureView, rhs: ReasoningDisclosureView) -> Bool {
        lhs.reasoning == rhs.reasoning
            && lhs.preparedReasoningContent == rhs.preparedReasoningContent
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isPreviewing == rhs.isPreviewing
            && lhs.suppressContentRender == rhs.suppressContentRender
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.usesNoBubbleStyle == rhs.usesNoBubbleStyle
            && lhs.isShimmering == rhs.isShimmering
            && Self.colorSignature(lhs.customTextColor) == Self.colorSignature(rhs.customTextColor)
            && lhs.previewMaxHeight == rhs.previewMaxHeight
            && lhs.enableMarkdown == rhs.enableMarkdown
            && lhs.enableAdvancedRenderer == rhs.enableAdvancedRenderer
            && lhs.enableMathRendering == rhs.enableMathRendering
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
            Button {
                if isPreviewing {
                    isExpanded = true
                } else {
                    isExpanded.toggle()
                }
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
                        .rotationEffect(.degrees(isFullyExpanded ? 90 : 0))
                        .foregroundStyle(baseColor)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if shouldShowContent {
                let contentColor = resolvedSecondaryTextColor(
                    default: usesNoBubbleStyle
                        ? Color.secondary
                        : (isOutgoing ? Color.white.opacity(0.85) : Color.secondary),
                    customTextColor: customTextColor,
                    customOpacity: 0.85
                )
                ReasoningPreviewContent(
                    isPreviewing: isPreviewing,
                    maxHeight: previewMaxHeight,
                    contentID: reasoning
                ) {
                    ReasoningMarkdownContentView(
                        reasoning: reasoning,
                        preparedReasoningContent: preparedReasoningContent,
                        enableMarkdown: enableMarkdown,
                        enableAdvancedRenderer: enableAdvancedRenderer,
                        enableMathRendering: enableMathRendering,
                        isOutgoing: isOutgoing,
                        textColor: contentColor,
                        font: .subheadline
                    )
                    .padding(.top, 8)
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

    private static func colorSignature(_ color: Color?) -> String? {
        guard let color else { return nil }
        return ChatAppearanceColorCodec.hexRGBA(from: color)
    }
}
