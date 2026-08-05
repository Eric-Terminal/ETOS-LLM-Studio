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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            to: textView,
            reduceMotion: reduceMotion
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

        let basePointSize: CGFloat = 17 * CGFloat(fontScale)
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
            font = UIFont.preferredFont(forTextStyle: .body)
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

    final class Coordinator {
        var lastBlockID: ETStreamingMarkdownBlockID?
        var lastText = ""
        var lastPresentation: ETStreamingMarkdownActivePresentation?
        var lastStyleSignature = ""
        var lastMeasuredHeight: CGFloat = 0

        func apply(
            _ block: ETStreamingMarkdownActiveBlock,
            style: Style,
            to textView: UITextView,
            reduceMotion: Bool
        ) {
            guard lastBlockID != block.id || lastText != block.displayText
                    || lastStyleSignature != style.signature else {
                return
            }

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

            if canAppend {
                let fullText = block.displayText as NSString
                let previousLength = (lastText as NSString).length
                let appended = fullText.substring(from: previousLength)
                guard !appended.isEmpty else {
                    remember(block, style: style)
                    return
                }
                addFadeIfNeeded(to: textView, reduceMotion: reduceMotion)
                textView.textStorage.beginEditing()
                textView.textStorage.append(
                    NSAttributedString(string: appended, attributes: style.attributes)
                )
                textView.textStorage.endEditing()
            } else {
                textView.layer.removeAnimation(forKey: "ETStreamingMarkdownFade")
                textView.textStorage.setAttributedString(
                    NSAttributedString(string: block.displayText, attributes: style.attributes)
                )
            }

            remember(block, style: style)
            invalidateHeightIfNeeded(for: textView)
        }

        private func addFadeIfNeeded(to textView: UITextView, reduceMotion: Bool) {
            guard !reduceMotion else {
                textView.layer.removeAnimation(forKey: "ETStreamingMarkdownFade")
                return
            }
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.22
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            textView.layer.add(transition, forKey: "ETStreamingMarkdownFade")
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
}
