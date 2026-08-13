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

    @Test("内部正文绘制越过缓存行高时仍能识别重叠")
    func detectsRenderedContentOverflowBeyondCachedRowFrame() {
        let upperMessageID = UUID()
        let lowerMessageID = UUID()
        let metadata = ChatMessageLayoutMetadata(
            role: "assistant",
            contentUTF8Length: 120,
            reasoningUTF8Length: 0,
            isAwaitingStaticHandoff: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false,
            layoutRevision: 1,
            recoveryRevision: 0,
            rendererHandoffRevision: 1,
            rendererHandoffAt: Date(),
            usesNoBubbleStyle: true,
            contentRenderer: .nativeMarkdown,
            reasoningRenderer: .none,
            layoutWidthBucket: 40
        )
        let frames = ChatMessageLayoutAudit.effectiveFrames(
            samples: [
                upperMessageID: ChatMessageLayoutSample(
                    frame: CGRect(x: 0, y: 80, width: 300, height: 100),
                    metadata: metadata
                ),
                lowerMessageID: ChatMessageLayoutSample(
                    frame: CGRect(x: 0, y: 180, width: 300, height: 100),
                    metadata: metadata
                )
            ],
            contentFrames: [
                upperMessageID: CGRect(x: 0, y: 80, width: 300, height: 180),
                lowerMessageID: CGRect(x: 0, y: 180, width: 300, height: 100)
            ]
        )

        let overlap = ChatMessageLayoutAudit.firstOverlap(
            orderedMessageIDs: [upperMessageID, lowerMessageID],
            frames: frames,
            viewportHeight: 600
        )
        #expect(overlap?.overlapHeight == 80)
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

    @Test("气泡身份包含无气泡模式、渲染器和宽度档位")
    func layoutIdentityTracksEveryHeightAffectingDimension() {
        let messageID = UUID()
        let baseline = ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 3,
            isStreaming: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false,
            usesNoBubbleStyle: false,
            contentRenderer: .nativeMarkdown,
            layoutWidthBucket: 40
        )

        #expect(baseline != ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 3,
            isStreaming: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false,
            usesNoBubbleStyle: true,
            contentRenderer: .nativeMarkdown,
            layoutWidthBucket: 40
        ))
        #expect(baseline != ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 3,
            isStreaming: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false,
            contentRenderer: .webMarkdown,
            layoutWidthBucket: 40
        ))
        #expect(baseline != ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 3,
            isStreaming: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false,
            contentRenderer: .nativeMarkdown,
            layoutWidthBucket: 41
        ))
    }

    @Test("最终行高复核必须使用主动请求后的新快照")
    func finalHeightVerificationRequiresFreshProbeSnapshot() {
        #expect(!ChatMessageLayoutAudit.isFreshVerificationSample(
            baselineSnapshotRevision: 8,
            currentSnapshotRevision: 8,
            requestedProbeRevision: 3,
            reportedProbeRevision: 3
        ))
        #expect(!ChatMessageLayoutAudit.isFreshVerificationSample(
            baselineSnapshotRevision: 8,
            currentSnapshotRevision: 9,
            requestedProbeRevision: 3,
            reportedProbeRevision: 2
        ))
        #expect(ChatMessageLayoutAudit.isFreshVerificationSample(
            baselineSnapshotRevision: 8,
            currentSnapshotRevision: 9,
            requestedProbeRevision: 3,
            reportedProbeRevision: 3
        ))
    }

    @Test("局部恢复耗尽后只升级一次消息栈重建")
    func recoveryEscalatesFromMessagesToStackAndThenStops() {
        #expect(ChatMessageLayoutAudit.recoveryAction(
            localAttempts: 0,
            stackAttempts: 0
        ) == .rebuildMessages)
        #expect(ChatMessageLayoutAudit.recoveryAction(
            localAttempts: 2,
            stackAttempts: 0
        ) == .rebuildStack)
        #expect(ChatMessageLayoutAudit.recoveryAction(
            localAttempts: 2,
            stackAttempts: 1
        ) == .stop)
    }

    @Test("整栈恢复选择最接近视口中央的可见消息")
    func stackRecoveryChoosesCentralVisibleAnchor() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let anchor = ChatMessageLayoutAudit.viewportAnchor(
            orderedMessageIDs: [first, second, third],
            frames: [
                first: CGRect(x: 0, y: -80, width: 300, height: 120),
                second: CGRect(x: 0, y: 80, width: 300, height: 220),
                third: CGRect(x: 0, y: 340, width: 300, height: 160)
            ],
            viewportHeight: 500
        )

        #expect(anchor == ChatLayoutViewportAnchor(messageID: second, minY: 80))
    }

    @Test("阅读锚点校正保持相对位置并服从滚动边界")
    func anchorAdjustmentPreservesRelativePositionWithinBounds() {
        #expect(ChatScrollMetricsObserver.anchorAdjustedContentOffsetY(
            currentOffsetY: 200,
            deltaY: 48,
            minimumOffsetY: 0,
            maximumOffsetY: 700
        ) == 248)
        #expect(ChatScrollMetricsObserver.anchorAdjustedContentOffsetY(
            currentOffsetY: 680,
            deltaY: 48,
            minimumOffsetY: 0,
            maximumOffsetY: 700
        ) == 700)
    }

    @Test("布局诊断不包含原始消息 UUID 或聊天正文")
    func diagnosticUsesAnonymousAliasesWithoutMessageContent() {
        let rawMessageID = UUID()
        let metadata = ChatMessageLayoutMetadata(
            role: "assistant",
            contentUTF8Length: 18,
            reasoningUTF8Length: 0,
            isAwaitingStaticHandoff: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false,
            layoutRevision: 4,
            recoveryRevision: 1,
            rendererHandoffRevision: 1,
            rendererHandoffAt: Date(timeIntervalSinceNow: -0.12),
            usesNoBubbleStyle: true,
            contentRenderer: .nativeMarkdown,
            reasoningRenderer: .none,
            layoutWidthBucket: 40
        )
        let context = ChatLayoutAuditContext(
            sessionID: UUID(),
            viewportSize: CGSize(width: 390, height: 844),
            isChatVisible: true,
            isAppActive: true,
            isUserInteracting: false,
            isSendingMessage: false,
            isLayoutSettling: false,
            isHistoryLoadInFlight: false,
            hasProgrammaticScrollTarget: false,
            hasSendFlight: false,
            scrollAnimationEnabled: true,
            settleDelayNanoseconds: 450_000_000,
            usesNoBubbleUI: true,
            fontScale: 1,
            systemVersion: "26.5"
        )
        let diagnostic = ChatLayoutDiagnosticFormatter.description(
            stage: "message-rebuild",
            upperAlias: "m1",
            lowerAlias: "m2",
            upperSample: ChatMessageLayoutSample(
                frame: CGRect(x: 8, y: 100, width: 374, height: 180),
                metadata: metadata
            ),
            lowerSample: ChatMessageLayoutSample(
                frame: CGRect(x: 8, y: 260, width: 374, height: 120),
                metadata: metadata
            ),
            upperContentFrame: CGRect(x: 8, y: 100, width: 374, height: 180),
            lowerContentFrame: CGRect(x: 8, y: 260, width: 374, height: 120),
            overlapHeight: 20,
            attempt: 1,
            context: context
        )

        #expect(!diagnostic.contains(rawMessageID.uuidString))
        #expect(!diagnostic.contains("不可记录的聊天正文"))
        #expect(diagnostic.contains("id:m1"))
        #expect(diagnostic.contains("contentBytes:18"))
        #expect(diagnostic.contains("rowFrame:{"))
        #expect(diagnostic.contains("contentFrame:{"))
    }
}
