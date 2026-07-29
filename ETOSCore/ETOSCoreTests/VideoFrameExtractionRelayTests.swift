// ============================================================================
// VideoFrameExtractionRelayTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证 watchOS 视频抽帧中继会在配对 iPhone 不可达时立即拒绝请求。
// ============================================================================

#if canImport(WatchConnectivity)
import Testing
@testable import ETOSCore

@Suite("视频抽帧中继")
struct VideoFrameExtractionRelayTests {
    @Test("配对 iPhone 当前不可达时立即拒绝抽帧")
    func rejectsUnreachableCompanion() {
        #expect(throws: VideoFrameExtractionRelayError.companionUnreachable) {
            try VideoFrameExtractionRelay.validateCompanionAvailability(
                isActivated: true,
                isCompanionAppInstalled: true,
                isReachable: false
            )
        }
    }

    @Test("配对 iPhone 可达时允许开始抽帧")
    func acceptsReachableCompanion() throws {
        try VideoFrameExtractionRelay.validateCompanionAvailability(
            isActivated: true,
            isCompanionAppInstalled: true,
            isReachable: true
        )
    }
}
#endif
