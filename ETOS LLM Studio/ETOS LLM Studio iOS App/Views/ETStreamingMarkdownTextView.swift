// ============================================================================
// ETStreamingMarkdownTextView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 流式活动 Block：使用 TextKit 2 在尾部增量写入，避免重排历史 Block。
// ============================================================================

import ETOSCore
import SwiftUI
import UIKit

struct ETStreamingMarkdownTextView: UIViewRepresentable {
    let activeBlock: ETStreamingMarkdownActiveBlock
    let textColor: Color
    let fontScale: Double
    let lineSpacing: CGFloat
    let streamingDisplayMode: ChatStreamingDisplayMode

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        _ = textView.textLayoutManager
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let style = resolvedStyle()
        context.coordinator.apply(
            activeBlock,
            style: style,
            revealDuration: streamingDisplayMode.textRevealDuration,
            reduceMotion: accessibilityReduceMotion,
            to: textView
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let height = ceil(measured.height)
        if abs(context.coordinator.lastMeasuredHeight - height) > 0.5 {
            context.coordinator.lastMeasuredHeight = height
        }
        return CGSize(width: width, height: height)
    }

    private func resolvedStyle() -> Style {
        let role: FontSemanticRole
        switch activeBlock.presentation {
        case .markdownSource:
            role = .body
        case .code, .mermaidSource:
            role = .code
        }

        // MarkdownUI 会在 Font.withProperties 中先取整字号，再创建 system/custom Font。
        // TextKit 使用同一字号规则，避免流式与静态状态之间出现细微的行高跳变。
        let basePointSize = round(17 * CGFloat(fontScale))
        let font: UIFont
        if let postScriptName = FontLibrary.resolvePostScriptName(
            for: role,
            sampleText: activeBlock.displayText
        ), let customFont = UIFont(name: postScriptName, size: basePointSize) {
            font = UIFontMetrics(forTextStyle: .body).scaledFont(for: customFont)
        } else if role == .code {
            let base = UIFont.monospacedSystemFont(ofSize: basePointSize, weight: .regular)
            font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        } else {
            let base = UIFont.systemFont(ofSize: basePointSize, weight: .regular)
            font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        return Style(
            font: font,
            color: UIColor(textColor),
            paragraphStyle: paragraphStyle
        )
    }
}

extension ETStreamingMarkdownTextView {
    struct Style {
        let font: UIFont
        let color: UIColor
        let paragraphStyle: NSParagraphStyle

        var signature: String {
            "\(font.fontName)|\(font.pointSize)|\(color.description)|\(paragraphStyle.lineSpacing)"
        }

        var attributes: [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        }
    }

    @MainActor
    final class Coordinator {
        var lastBlockID: ETStreamingMarkdownBlockID?
        var lastText = ""
        var lastPresentation: ETStreamingMarkdownActivePresentation?
        var lastStyleSignature = ""
        var lastMeasuredHeight: CGFloat = 0
        private let textFadeAnimator = TextFadeAnimator()

        func apply(
            _ block: ETStreamingMarkdownActiveBlock,
            style: Style,
            revealDuration: TimeInterval = ChatStreamingDisplayMode.immediate.textRevealDuration,
            reduceMotion: Bool = false,
            to textView: UITextView
        ) {
            if reduceMotion {
                textFadeAnimator.finishImmediately(in: textView.textStorage)
            }
            guard lastBlockID != block.id || lastText != block.displayText
                    || lastStyleSignature != style.signature else {
                return
            }

            // 整层交叉淡化会把换行前后的两份文字叠在一起；高速流式更新时表现为横向重影。
            // 文字排版立即落位，纵向连续性由外层滚动锚点负责。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            let canAppend: Bool
            switch block.updateKind {
            case .append(let previousUTF16Length):
                canAppend = previousUTF16Length == (lastText as NSString).length
                    && (block.displayText as NSString).length >= previousUTF16Length
                    && block.displayText.hasPrefix(lastText)
                    && lastPresentation == block.presentation
                    && lastStyleSignature == style.signature
            case .reset:
                canAppend = false
            }
            let revealsNewBlock = !reduceMotion && lastBlockID != block.id

            if canAppend {
                let fullText = block.displayText as NSString
                let previousLength = (lastText as NSString).length
                let appended = fullText.substring(from: previousLength)
                guard !appended.isEmpty else {
                    remember(block, style: style)
                    return
                }
                textView.textStorage.beginEditing()
                textView.textStorage.append(
                    NSAttributedString(string: appended, attributes: style.attributes)
                )
                textView.textStorage.endEditing()

                if !reduceMotion {
                    textFadeAnimator.reveal(
                        range: NSRange(location: previousLength, length: (appended as NSString).length),
                        color: style.color,
                        duration: revealDuration,
                        in: textView
                    )
                }
            } else {
                textFadeAnimator.finishImmediately(in: textView.textStorage)
                textView.textStorage.setAttributedString(
                    NSAttributedString(string: block.displayText, attributes: style.attributes)
                )
                if revealsNewBlock {
                    textFadeAnimator.reveal(
                        range: NSRange(location: 0, length: textView.textStorage.length),
                        color: style.color,
                        duration: revealDuration,
                        in: textView
                    )
                }
            }

            remember(block, style: style)
            invalidateHeightIfNeeded(for: textView)
        }

        private func remember(_ block: ETStreamingMarkdownActiveBlock, style: Style) {
            lastBlockID = block.id
            lastText = block.displayText
            lastPresentation = block.presentation
            lastStyleSignature = style.signature
        }

        private func invalidateHeightIfNeeded(for textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0 else {
                textView.invalidateIntrinsicContentSize()
                return
            }
            let measured = ceil(textView.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            ).height)
            guard abs(lastMeasuredHeight - measured) > 0.5 else { return }
            lastMeasuredHeight = measured
            textView.invalidateIntrinsicContentSize()
        }
    }

    /// 仅修改新增字符的前景色透明度，避免触发布局重算或整层交叉叠影。
    @MainActor
    final class TextFadeAnimator: NSObject {
        private struct Run {
            let range: NSRange
            let color: UIColor
            let startedAt: CFTimeInterval
            let duration: TimeInterval
        }

        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var runs: [Run] = []

        func reveal(
            range: NSRange,
            color: UIColor,
            duration: TimeInterval,
            in textView: UITextView
        ) {
            guard range.length > 0, duration > 0 else { return }
            self.textView = textView
            textView.textStorage.addAttribute(
                .foregroundColor,
                value: color.withAlphaComponent(0),
                range: range
            )
            runs.append(
                Run(
                    range: range,
                    color: color,
                    startedAt: CACurrentMediaTime(),
                    duration: duration
                )
            )
            startDisplayLinkIfNeeded()
            textView.setNeedsDisplay()
        }

        func finishImmediately(in textStorage: NSTextStorage) {
            guard !runs.isEmpty else { return }
            textStorage.beginEditing()
            for run in runs where NSMaxRange(run.range) <= textStorage.length {
                textStorage.addAttribute(.foregroundColor, value: run.color, range: run.range)
            }
            textStorage.endEditing()
            runs.removeAll(keepingCapacity: true)
            stopDisplayLink()
            textView?.setNeedsDisplay()
        }

        private func startDisplayLinkIfNeeded() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(updateFade(_:)))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func updateFade(_ link: CADisplayLink) {
            guard let textView else {
                runs.removeAll(keepingCapacity: false)
                stopDisplayLink()
                return
            }

            let now = link.timestamp
            var remainingRuns: [Run] = []
            remainingRuns.reserveCapacity(runs.count)
            textView.textStorage.beginEditing()
            for run in runs {
                guard NSMaxRange(run.range) <= textView.textStorage.length else { continue }
                let progress = min(max((now - run.startedAt) / run.duration, 0), 1)
                // easeOutCubic 让字形先快速可读，再平缓落到完整不透明度。
                let easedProgress = 1 - pow(1 - progress, 3)
                textView.textStorage.addAttribute(
                    .foregroundColor,
                    value: run.color.withAlphaComponent(
                        run.color.cgColor.alpha * CGFloat(easedProgress)
                    ),
                    range: run.range
                )
                if progress < 1 {
                    remainingRuns.append(run)
                }
            }
            textView.textStorage.endEditing()
            runs = remainingRuns
            textView.setNeedsDisplay()

            if runs.isEmpty {
                stopDisplayLink()
            }
        }
    }
}
