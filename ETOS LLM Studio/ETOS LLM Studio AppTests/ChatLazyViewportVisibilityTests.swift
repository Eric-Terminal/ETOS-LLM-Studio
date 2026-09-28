import CoreGraphics
import ETOSCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("真实惰性列表与原生偏移的可见性", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatLazyViewportVisibilityTests {
    @Test("生产滚动桥挂载后原生偏移必须实现中段、末段并返回首屏内容")
    func nativeOffsetRealizesExpectedRows() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: LazyViewportContent())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        // 只允许初次挂载布局；之后任何一站都不能靠强制布局、代理滚动或视图重建恢复。
        host.view.layoutIfNeeded()
        let attachmentDeadline = ContinuousClock.now + .seconds(3)
        while observer(in: host.view)?.coordinator?.scrollView == nil,
              ContinuousClock.now < attachmentDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let observer = try #require(self.observer(in: host.view))
        let bridge = try #require(observer.coordinator)
        let scrollView = try #require(bridge.scrollView)
        try #require(scrollView.window === window)
        try #require(observer.isDescendant(of: scrollView))

        let contentHeight = CGFloat(LazyViewportContent.rowCount) * LazyViewportContent.rowHeight
        let geometryDeadline = ContinuousClock.now + .seconds(3)
        while (abs(scrollView.contentSize.height - contentHeight) > 0.5 || scrollView.bounds.height < 400),
              ContinuousClock.now < geometryDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(abs(scrollView.contentSize.height - contentHeight) < 0.5)
        try #require(scrollView.bounds.height >= 400)
        try #require(Set((0..<LazyViewportContent.rowCount).map(LazyViewportContent.channels)).count
            == LazyViewportContent.rowCount)

        let top = -scrollView.adjustedContentInset.top
        let bottom = contentHeight - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        let stations: [(String, CGFloat, [Int])] = [
            ("首屏", top, [0, 1]),
            ("首次进入中段", 43 * LazyViewportContent.rowHeight + top, [43, 44]),
            ("首次进入末段", bottom, [94, 95]),
            ("返回首屏", top, [0, 1])
        ]
        for (stage, offsetY, expectedRows) in stations {
            if stage != "首屏" {
                scrollView.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
            }
            try await requireVisibleRows(
                expectedRows, stage: stage, offsetY: offsetY, host: host.view,
                scrollView: scrollView, observer: observer, bridge: bridge
            )
        }
        // 此用例只覆盖原生偏移与 SwiftUI 实现范围的通信；真实 pan、键盘和发送仍需独立验收。
    }

    private func requireVisibleRows(
        _ rows: [Int], stage: String, offsetY: CGFloat, host: UIView,
        scrollView: UIScrollView, observer: ChatScrollMetricsObserver.ObserverView,
        bridge: ChatScrollMetricsObserver.Coordinator
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        var matches = false
        var lastImage: UIImage?
        var sampleDescription = "尚未取样"
        repeat {
            // 只让真实 RunLoop 推进。像素读取不调用 afterScreenUpdates 或任何布局/滚动写入。
            try await Task.sleep(for: .milliseconds(50))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { context in
                host.layer.render(in: context.cgContext)
            }
            lastImage = image
            let bitmap = try #require(image.cgImage)
            let viewport = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
            var allPatchesMatch = true
            var descriptions: [String] = []
            for row in rows {
                let expected = LazyViewportContent.channels(row)
                for x in [CGFloat(16), scrollView.bounds.width - 16] {
                    let contentPoint = CGPoint(x: x, y: CGFloat(row) * LazyViewportContent.rowHeight + 24)
                    let hostPoint = scrollView.convert(contentPoint, to: host)
                    guard viewport.contains(contentPoint), host.bounds.contains(hostPoint) else {
                        allPatchesMatch = false
                        descriptions.append("行\(row)取样点不在真实视口内")
                        continue
                    }
                    let patch = CGRect(x: floor(hostPoint.x) - 1, y: floor(hostPoint.y) - 1, width: 3, height: 3)
                    let cropped = try #require(bitmap.cropping(to: patch))
                    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                    let context = try #require(CGContext(
                        data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                        space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 3, height: 3))
                    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
                    for pixel in 0..<9 {
                        // 仅容纳 sRGB 的一个量化单位；每行唯一颜色，旧行、透明或空白不能匹配。
                        let start = pixel * 4
                        let colorMatches = (0..<3).allSatisfy {
                            abs(Int(bytes[start + $0]) - Int(expected[$0])) <= 1
                        }
                        allPatchesMatch = allPatchesMatch && colorMatches && bytes[start + 3] == 255
                    }
                    descriptions.append("行\(row) x\(Int(x)) RGBA=\(Array(UnsafeBufferPointer(start: bytes, count: 4))) 预期=\(expected)")
                }
            }
            sampleDescription = descriptions.joined(separator: "；")
            matches = allPatchesMatch && abs(scrollView.contentOffset.y - offsetY) < 0.5
        } while !matches && ContinuousClock.now < deadline

        let details = "阶段=\(stage) offset=\(scrollView.contentOffset) 预期offset=\(offsetY) "
            + "contentSize=\(scrollView.contentSize) bounds=\(scrollView.bounds) inset=\(scrollView.adjustedContentInset)；"
            + sampleDescription
        Attachment.record(Data(details.utf8), named: "惰性列表-\(stage).txt")
        if let png = lastImage?.pngData() {
            Attachment.record(png, named: "惰性列表-\(stage).png")
        }
        try #require(observer.coordinator === bridge)
        try #require(bridge.scrollView === scrollView)
        try #require(scrollView.window != nil)
        try #require(abs(scrollView.contentOffset.y - offsetY) < 0.5, "原生偏移没有到达本次目标")
        try #require(matches, "原生偏移已改变，但真实视口没有显示对应行的非空像素")
    }

    private func observer(in view: UIView) -> ChatScrollMetricsObserver.ObserverView? {
        if let observer = view as? ChatScrollMetricsObserver.ObserverView { return observer }
        return view.subviews.lazy.compactMap { observer(in: $0) }.first
    }
}

@MainActor
private struct LazyViewportContent: View {
    static let rowCount = 96
    static let rowHeight: CGFloat = 96

    static func channels(_ row: Int) -> [UInt8] {
        [UInt8(31 + (row * 73 + 17) % 193), UInt8(31 + (row * 47 + 61) % 193), UInt8(31 + (row * 29 + 97) % 193)]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 与聊天页相同：生产桥位于内容 VStack 内，紧邻真正的 LazyVStack。
                ChatScrollMetricsObserver(
                    keepsBottomPinned: .constant(false), isStreaming: false,
                    streamingDisplayMode: .immediate, reduceMotion: false,
                    metricsRefreshGeneration: 0,
                    metricThresholds: .init(arrival: 1, bottomPinned: 24, bottomButton: 48, historyLoading: 240),
                    isViewportTransitioning: false, hasProgrammaticScrollCommand: false,
                    anchorAdjustment: nil, onAnchorAdjustmentApplied: { _ in },
                    viewportPageRequest: nil, onViewportPageRequestCompleted: { _ in },
                    onUserPanBegan: {}, onMetricsChange: { _, _, _ in }
                )
                .frame(width: 0, height: 0)
                LazyVStack(spacing: 0) {
                    ForEach(0..<Self.rowCount, id: \.self) { row in
                        let components = Self.channels(row)
                        Color(.sRGB, red: Double(components[0]) / 255,
                              green: Double(components[1]) / 255, blue: Double(components[2]) / 255, opacity: 1)
                            .frame(height: Self.rowHeight)
                            .overlay {
                                Text("惰性列表唯一行标 \(row)")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.black)
                            }
                    }
                }
                .scrollTargetLayout()
            }
        }
        .scrollIndicators(.hidden)
        .environment(\.scenePhase, .active)
        .ignoresSafeArea()
    }
}
