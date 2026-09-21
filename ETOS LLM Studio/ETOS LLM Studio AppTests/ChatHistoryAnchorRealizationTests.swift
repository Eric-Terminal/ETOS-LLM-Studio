import Combine
import CoreGraphics
import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
struct ChatHistoryAnchorRealizationTests {
    @Test("扩窗移出懒布局的锚点只请求一次定位，并保留加载前的滚动基准", .timeLimit(.minutes(1)))
    func preservesOriginalOffsetAfterRealization() async throws {
        let controller = ChatHistoryViewportAnchorController()
        let anchorID = UUID()
        let earlierID = UUID()
        let updatedIDs = [earlierID, anchorID]
        controller.updateFrames(
            [anchorID: CGRect(x: 0, y: 120, width: 300, height: 80)],
            displayedMessageIDs: [anchorID]
        )
        #expect(controller.beginMutation(
            anchorMessageID: anchorID,
            displayedMessageIDs: [anchorID],
            referenceDistanceToTop: 75
        ))
        controller.updateFrames(
            [anchorID: CGRect(x: 0, y: 200, width: 300, height: 80)],
            displayedMessageIDs: updatedIDs
        )
        // 下一次布局移除了锚点，前一帧排队的校正不能提交。
        controller.updateFrames(
            [earlierID: CGRect(x: 0, y: 0, width: 300, height: 240)],
            displayedMessageIDs: updatedIDs
        )
        try await Task.sleep(for: .milliseconds(120))
        #expect(controller.pendingAdjustment == nil)
        #expect(controller.takeAnchorRealizationRequest(displayedMessageIDs: updatedIDs) == anchorID)
        #expect(controller.takeAnchorRealizationRequest(displayedMessageIDs: updatedIDs) == nil)
        controller.updateFrames(
            [anchorID: CGRect(x: 0, y: 360, width: 300, height: 80)],
            displayedMessageIDs: updatedIDs
        )
        for await candidate in controller.$pendingAdjustment.values {
            guard let adjustment = candidate else { continue }
            #expect(adjustment.deltaY == 240)
            #expect(adjustment.referenceDistanceToTop == 75)
            #expect(controller.completeAdjustment(id: adjustment.id))
            #expect(!controller.isRestoringAnchor)
            return
        }
        Issue.record("锚点重新布局后未发布位置校正")
    }
}
