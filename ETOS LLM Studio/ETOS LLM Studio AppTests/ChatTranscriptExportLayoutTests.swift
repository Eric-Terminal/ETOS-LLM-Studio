// ============================================================================
// ChatTranscriptExportLayoutTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖聊天长图在异步内容改变高度时的布局稳定判定。
// ============================================================================

import Combine
import CoreGraphics
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

struct ChatTranscriptExportLayoutTests {
    @MainActor
    @Test("真实画布截图等待文字重载的后台字体完成")
    func captureWaitsForPreparedFonts() async throws {
        let enabled = FontLibrary.isCustomFontEnabled
        let scope = FontLibrary.fallbackScope
        let scale = FontLibrary.customFontScale
        defer {
            FontLibrary.updateRuntimeSettings(isCustomFontEnabled: enabled, fallbackScope: scope, customFontScale: scale)
        }
        let canvas = Text(verbatim: "字体 Font")
            .etFont(.body)
            .environment(\.sizeCategory, .extraExtraLarge)
            .frame(width: 200)
            .fixedSize(horizontal: false, vertical: true)
        FontLibrary.updateRuntimeSettings(isCustomFontEnabled: false, fallbackScope: .segment, customFontScale: 1)
        let sourceWindow = try sourceWindow()
        let regular = try await ChatTranscriptSwiftUIImageCapture.capture(
            canvas: canvas, width: 200, viewportHeight: 400, prefersDarkAppearance: false,
            sourceWindow: sourceWindow
        )
        FontLibrary.updateRuntimeSettings(isCustomFontEnabled: false, fallbackScope: .segment, customFontScale: 2)
        let enlarged = try await ChatTranscriptSwiftUIImageCapture.capture(
            canvas: canvas, width: 200, viewportHeight: 400, prefersDarkAppearance: false,
            sourceWindow: sourceWindow
        )
        #expect(enlarged.image.height > regular.image.height * 3 / 2)
    }

    @Test("导出高度连续稳定后才开始截图")
    func waitsForStableHeightBeforeCapture() {
        var tracker = ChatTranscriptExportHeightTracker()

        let firstRecordIsStable = tracker.record(800)
        let secondRecordIsStable = tracker.record(800)
        let thirdRecordIsStable = tracker.record(800)

        #expect(!firstRecordIsStable)
        #expect(!secondRecordIsStable)
        #expect(thirdRecordIsStable)
    }

    @Test("导出高度变化会重新等待布局稳定")
    func heightChangeRestartsStabilityCheck() {
        var tracker = ChatTranscriptExportHeightTracker()

        let firstRecordIsStable = tracker.record(800)
        let secondRecordIsStable = tracker.record(800)
        let changedRecordIsStable = tracker.record(1_200)
        let nearbyRecordIsStable = tracker.record(1_200.25)
        let settledRecordIsStable = tracker.record(1_200)

        #expect(!firstRecordIsStable)
        #expect(!secondRecordIsStable)
        #expect(!changedRecordIsStable)
        #expect(!nearbyRecordIsStable)
        #expect(settledRecordIsStable)
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
            prefersDarkAppearance: false,
            sourceWindow: try sourceWindow()
        )

        #expect(captured.image.width == 400)
        #expect(captured.image.height == 2_400)
    }

    @MainActor
    @Test("导出窗口来源随所在视图迁移，不绑定任意全局窗口")
    func sourceWindowFollowsHostingView() {
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let secondWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 744, height: 570))
        let view = UIView()
        let source = ChatTranscriptSourceWindow()
        source.view = view
        firstWindow.addSubview(view)
        #expect(source.window === firstWindow)
        secondWindow.addSubview(view)
        #expect(source.window === secondWindow)
        #expect(source.window?.bounds.size == CGSize(width: 744, height: 570))
        view.removeFromSuperview()
        #expect(source.window == nil)
    }

    @MainActor
    private func sourceWindow() throws -> UIWindow {
        // 仅测试夹具寻找宿主窗口；生产代码必须从实际发起导出的视图传入。
        try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow))
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
