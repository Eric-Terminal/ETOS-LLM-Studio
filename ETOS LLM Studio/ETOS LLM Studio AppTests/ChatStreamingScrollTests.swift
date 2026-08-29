// ============================================================================
// ChatStreamingScrollTests.swift
// ============================================================================
// 流式 Markdown、吸底策略与自动历史加载回归测试。
// ============================================================================

import Foundation
import SwiftUI
import Testing
import UIKit
import ETOSCore
@testable import ETOS_LLM_Studio_App

struct ChatStreamingScrollTests {

    @Test("流式 Markdown 只在 Block 准备完成前冻结结构变化")
    func testStreamingMarkdownDefersOnlyNewCommittedStructure() {
        let messageID = UUID()
        let firstID = ETStreamingMarkdownBlockID(messageID: messageID, ordinal: 0)
        let secondID = ETStreamingMarkdownBlockID(messageID: messageID, ordinal: 1)
        let firstBlock = ETStreamingMarkdownBlock(
            id: firstID,
            source: "第一段\n\n",
            kind: .markdown,
            leadingSpacingEm: 0
        )
        let secondBlock = ETStreamingMarkdownBlock(
            id: secondID,
            source: "第二段\n\n",
            kind: .markdown,
            leadingSpacingEm: 1
        )
        let displayed = ETStreamingMarkdownSnapshot(
            messageID: messageID,
            sourceText: "第一段\n\n",
            revision: 1,
            committedBlocks: [firstBlock],
            activeBlock: nil,
            isFinal: false
        )
        let activeOnlyUpdate = ETStreamingMarkdownSnapshot(
            messageID: messageID,
            sourceText: "第一段\n\n更新",
            revision: 2,
            committedBlocks: [firstBlock],
            activeBlock: nil,
            isFinal: false
        )
        let appendedStructure = ETStreamingMarkdownSnapshot(
            messageID: messageID,
            sourceText: "第一段\n\n第二段\n\n",
            revision: 3,
            committedBlocks: [firstBlock, secondBlock],
            activeBlock: nil,
            isFinal: false
        )
        let emptyStructure = ETStreamingMarkdownSnapshot(
            messageID: messageID,
            sourceText: "",
            revision: 4,
            committedBlocks: [],
            activeBlock: nil,
            isFinal: false
        )

        #expect(ETIOSStreamingMarkdownLiveView.canDisplayImmediately(
            enableMarkdown: true,
            displayedSnapshot: displayed,
            incomingSnapshot: activeOnlyUpdate
        ))
        #expect(!ETIOSStreamingMarkdownLiveView.canDisplayImmediately(
            enableMarkdown: true,
            displayedSnapshot: displayed,
            incomingSnapshot: appendedStructure
        ))
        #expect(!ETIOSStreamingMarkdownLiveView.canDisplayImmediately(
            enableMarkdown: true,
            displayedSnapshot: nil,
            incomingSnapshot: appendedStructure
        ))
        #expect(ETIOSStreamingMarkdownLiveView.canDisplayImmediately(
            enableMarkdown: false,
            displayedSnapshot: displayed,
            incomingSnapshot: appendedStructure
        ))
        #expect(ETIOSStreamingMarkdownLiveView.canDisplayImmediately(
            enableMarkdown: true,
            displayedSnapshot: displayed,
            incomingSnapshot: emptyStructure
        ))
    }

    @Test("流式滚动只在内容超出视口后追随底部")
    func testStreamingOffsetRequiresScrollableContent() {
        #expect(!ChatScrollMetricsObserver.streamingContentOverflowsViewport(
            contentHeight: 748,
            boundsHeight: 748,
            bottomInset: 0
        ))
        #expect(!ChatScrollMetricsObserver.streamingContentOverflowsViewport(
            contentHeight: 748.5,
            boundsHeight: 748,
            bottomInset: 0
        ))
        #expect(ChatScrollMetricsObserver.streamingContentOverflowsViewport(
            contentHeight: 770,
            boundsHeight: 748,
            bottomInset: 0
        ))

        #expect(ChatScrollMetricsObserver.maximumContentOffsetY(
            contentHeight: 700,
            boundsHeight: 748,
            topInset: 0,
            bottomInset: 0
        ) == 0)
        #expect(ChatScrollMetricsObserver.maximumContentOffsetY(
            contentHeight: 800,
            boundsHeight: 748,
            topInset: 0,
            bottomInset: 0
        ) == 52)
    }

    @Test("拖动立即解除吸底且松手后仅在底部重新接管")
    func testBottomPinIntentPrioritizesUserInteraction() {
        #expect(!ChatView.resolvedBottomPinIntent(
            currentIntent: true,
            distanceToBottom: 0,
            arrivalTolerance: 1,
            isUserInteracting: true,
            isLayoutSettling: false
        ))
        #expect(ChatView.resolvedBottomPinIntent(
            currentIntent: true,
            distanceToBottom: 80,
            arrivalTolerance: 1,
            isUserInteracting: false,
            isLayoutSettling: false
        ))
        #expect(!ChatView.resolvedBottomPinIntent(
            currentIntent: false,
            distanceToBottom: 12,
            arrivalTolerance: 1,
            isUserInteracting: false,
            isLayoutSettling: false
        ))
        #expect(!ChatView.resolvedBottomPinIntent(
            currentIntent: false,
            distanceToBottom: 48,
            arrivalTolerance: 1,
            isUserInteracting: false,
            isLayoutSettling: false
        ))
        #expect(ChatView.resolvedBottomPinIntent(
            currentIntent: false,
            distanceToBottom: 0.5,
            arrivalTolerance: 1,
            isUserInteracting: false,
            isLayoutSettling: false
        ))
        #expect(!ChatView.resolvedBottomPinIntent(
            currentIntent: false,
            distanceToBottom: 0,
            arrivalTolerance: 1,
            isUserInteracting: false,
            isLayoutSettling: true
        ))
    }

    @MainActor
    @Test("高速流式追加只淡入新增文字且不动画整层")
    func testStreamingMarkdownAppendFadesOnlyNewText() {
        let messageID = UUID()
        let blockID = ETStreamingMarkdownBlockID(messageID: messageID, ordinal: 0)
        let paragraphStyle = NSMutableParagraphStyle()
        let style = ETStreamingMarkdownTextView.Style(
            font: .systemFont(ofSize: 17),
            color: .label,
            paragraphStyle: paragraphStyle
        )
        let textView = UITextView(usingTextLayoutManager: true)
        let coordinator = ETStreamingMarkdownTextView.Coordinator()
        let initialBlock = ETStreamingMarkdownActiveBlock(
            id: blockID,
            source: "Hello",
            displayText: "Hello",
            presentation: .markdownSource,
            updateKind: .reset,
            leadingSpacingEm: 0
        )
        coordinator.apply(initialBlock, style: style, reduceMotion: true, to: textView)

        let appendedBlock = ETStreamingMarkdownActiveBlock(
            id: blockID,
            source: "Hello world",
            displayText: "Hello world",
            presentation: .markdownSource,
            updateKind: .append(previousUTF16Length: 5),
            leadingSpacingEm: 0
        )
        coordinator.apply(appendedBlock, style: style, to: textView)

        #expect(textView.text == "Hello world")
        #expect(textView.layer.animationKeys()?.isEmpty ?? true)
        let originalColor = textView.textStorage.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? UIColor
        let appendedColor = textView.textStorage.attribute(
            .foregroundColor,
            at: 5,
            effectiveRange: nil
        ) as? UIColor
        #expect(originalColor?.cgColor.alpha == 1)
        #expect(appendedColor?.cgColor.alpha == 0)
    }

    @MainActor
    @Test("减少动态效果时新增文字立即完整显示")
    func testStreamingMarkdownAppendRespectsReduceMotion() {
        let messageID = UUID()
        let blockID = ETStreamingMarkdownBlockID(messageID: messageID, ordinal: 0)
        let style = ETStreamingMarkdownTextView.Style(
            font: .systemFont(ofSize: 17),
            color: .systemBlue,
            paragraphStyle: NSMutableParagraphStyle()
        )
        let textView = UITextView(usingTextLayoutManager: true)
        let coordinator = ETStreamingMarkdownTextView.Coordinator()
        coordinator.apply(
            ETStreamingMarkdownActiveBlock(
                id: blockID,
                source: "A",
                displayText: "A",
                presentation: .markdownSource,
                updateKind: .reset,
                leadingSpacingEm: 0
            ),
            style: style,
            reduceMotion: true,
            to: textView
        )
        coordinator.apply(
            ETStreamingMarkdownActiveBlock(
                id: blockID,
                source: "AB",
                displayText: "AB",
                presentation: .markdownSource,
                updateKind: .append(previousUTF16Length: 1),
                leadingSpacingEm: 0
            ),
            style: style,
            reduceMotion: true,
            to: textView
        )

        let appendedColor = textView.textStorage.attribute(
            .foregroundColor,
            at: 1,
            effectiveRange: nil
        ) as? UIColor
        #expect(appendedColor?.cgColor.alpha == 1)
    }

    @Test("尺寸变化只在贴底状态下使用底部锚点")
    func testChatSizeChangeAnchorFollowsBottomIntent() {
        #expect(ChatView.chatSizeChangeScrollAnchor(
            keepsBottomPinned: true,
            isStreaming: false
        ) == .bottom)
        #expect(ChatView.chatSizeChangeScrollAnchor(
            keepsBottomPinned: false,
            isStreaming: false
        ) == nil)
        #expect(ChatView.chatSizeChangeScrollAnchor(
            keepsBottomPinned: true,
            isStreaming: true
        ) == nil)
    }

    @Test("自动历史窗口只在真实滚到边缘时记录一次加载意图")
    func testAutomaticHistoryLoadingRequiresEdgeInteraction() {
        let firstMessageID = UUID()

        #expect(!ChatView.shouldQueueAutomaticHistoryLoad(
            usesAutomaticHistoryWindow: true,
            isUserInteracting: false,
            distanceToEdge: 0,
            triggerDistance: 240,
            anchorMessageID: firstMessageID,
            lastLoadAnchorID: nil
        ))
        #expect(ChatView.shouldQueueAutomaticHistoryLoad(
            usesAutomaticHistoryWindow: true,
            isUserInteracting: true,
            distanceToEdge: 120,
            triggerDistance: 240,
            anchorMessageID: firstMessageID,
            lastLoadAnchorID: nil
        ))
        #expect(!ChatView.shouldQueueAutomaticHistoryLoad(
            usesAutomaticHistoryWindow: true,
            isUserInteracting: true,
            distanceToEdge: 120,
            triggerDistance: 240,
            anchorMessageID: firstMessageID,
            lastLoadAnchorID: firstMessageID
        ))

        #expect(ChatView.shouldQueueAutomaticHistoryLoad(
            usesAutomaticHistoryWindow: true,
            isUserInteracting: true,
            distanceToEdge: 120,
            triggerDistance: 240,
            anchorMessageID: firstMessageID,
            lastLoadAnchorID: nil
        ))

    }
}
