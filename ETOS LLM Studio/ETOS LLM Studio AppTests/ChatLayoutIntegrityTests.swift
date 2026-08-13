// ============================================================================
// ChatLayoutIntegrityTests.swift
// ============================================================================
// iOS 聊天列表布局审计与局部重测量回归测试
// ============================================================================

import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

struct ChatLayoutIntegrityTests {
    @Test("只识别位于视口安全区域的相邻消息重叠")
    func detectsAdjacentOverlapInsideViewport() {
        let upperMessageID = UUID()
        let lowerMessageID = UUID()
        let overlap = ChatMessageLayoutAudit.firstOverlap(
            orderedMessageIDs: [upperMessageID, lowerMessageID],
            frames: [
                upperMessageID: CGRect(x: 0, y: 80, width: 300, height: 100),
                lowerMessageID: CGRect(x: 0, y: 168, width: 300, height: 120)
            ],
            viewportHeight: 600
        )

        #expect(overlap == ChatMessageLayoutOverlap(
            upperMessageID: upperMessageID,
            lowerMessageID: lowerMessageID,
            overlapHeight: 12
        ))
    }

    @Test("忽略视口边缘由滚动过渡产生的短暂重叠")
    func ignoresOverlapAtViewportEdge() {
        let upperMessageID = UUID()
        let lowerMessageID = UUID()
        let overlap = ChatMessageLayoutAudit.firstOverlap(
            orderedMessageIDs: [upperMessageID, lowerMessageID],
            frames: [
                upperMessageID: CGRect(x: 0, y: -20, width: 300, height: 55),
                lowerMessageID: CGRect(x: 0, y: 28, width: 300, height: 90)
            ],
            viewportHeight: 600
        )

        #expect(overlap == nil)
    }

    @Test("正常相邻布局不会触发修复")
    func ignoresSeparatedMessages() {
        let upperMessageID = UUID()
        let lowerMessageID = UUID()
        let overlap = ChatMessageLayoutAudit.firstOverlap(
            orderedMessageIDs: [upperMessageID, lowerMessageID],
            frames: [
                upperMessageID: CGRect(x: 0, y: 80, width: 300, height: 100),
                lowerMessageID: CGRect(x: 0, y: 180, width: 300, height: 120)
            ],
            viewportHeight: 600
        )

        #expect(overlap == nil)
    }

    @Test("布局自愈 revision 只重建目标气泡身份")
    func recoveryRevisionChangesBubbleLayoutIdentity() {
        let messageID = UUID()
        let original = ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 5,
            layoutRecoveryRevision: 0,
            isStreaming: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false
        )
        let recovered = ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 5,
            layoutRecoveryRevision: 1,
            isStreaming: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false
        )

        #expect(original != recovered)
    }
}
