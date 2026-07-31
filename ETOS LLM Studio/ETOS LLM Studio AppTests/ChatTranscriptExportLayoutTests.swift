// ============================================================================
// ChatTranscriptExportLayoutTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖聊天长图在异步内容改变高度时的布局稳定判定。
// ============================================================================

import Combine
import CoreGraphics
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

struct ChatTranscriptExportLayoutTests {
    @Test("导出高度连续稳定后才开始截图")
    func waitsForStableHeightBeforeCapture() {
        var tracker = ChatTranscriptExportHeightTracker()

        #expect(!tracker.record(800))
        #expect(!tracker.record(800))
        #expect(tracker.record(800))
    }

    @Test("导出高度变化会重新等待布局稳定")
    func heightChangeRestartsStabilityCheck() {
        var tracker = ChatTranscriptExportHeightTracker()

        #expect(!tracker.record(800))
        #expect(!tracker.record(800))
        #expect(!tracker.record(1_200))
        #expect(!tracker.record(1_200.25))
        #expect(tracker.record(1_200))
    }

    @MainActor
    @Test("导出使用挂载后稳定的完整画布高度")
    func captureUsesSettledMountedCanvasHeight() async throws {
        let model = DeferredHeightModel()
        let canvas = DeferredHeightCanvas(model: model)
            .frame(width: 200)
            .fixedSize(horizontal: false, vertical: true)

        let captured = try await ChatTranscriptSwiftUIImageCapture.capture(
            canvas: canvas,
            width: 200,
            viewportHeight: 400,
            prefersDarkAppearance: false
        )

        #expect(captured.image.width == 400)
        #expect(captured.image.height == 2_400)
    }
}

@MainActor
private final class DeferredHeightModel: ObservableObject {
    @Published var height: CGFloat = 400
}

@MainActor
private struct DeferredHeightCanvas: View {
    @ObservedObject var model: DeferredHeightModel

    var body: some View {
        Color.red
            .frame(height: model.height)
            .task {
                await Task.yield()
                model.height = 1_200
            }
    }
}
