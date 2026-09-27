import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送来源真实内容捕获", .serialized)
@MainActor
struct ChatSendFlightSourceTests {
    @Test("真实编辑器只捕获可见文字且保留选区、字体与滚动位置", arguments: [false, true])
    func editorCapturePreservesVisibleContent(longDraft: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let host = UIViewController()
        host.view.backgroundColor = .magenta
        window.rootViewController = host
        let editor = UITextView(frame: CGRect(x: 20, y: 80, width: 260, height: 90))
        editor.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        editor.text = longDraft ? String(repeating: "前面的长草稿不应进入快照。\n", count: 100) + "正在阅读的最后几行" : "短句"
        editor.backgroundColor = .white
        host.view.addSubview(editor)
        let anchor = UIView(frame: editor.frame)
        anchor.isUserInteractionEnabled = false
        host.view.addSubview(anchor)
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        host.view.addSubview(surface)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(20))
        editor.layoutIfNeeded()
        editor.selectedRange = NSRange(location: 0, length: 1)
        if longDraft {
            editor.contentOffset.y = max(0, editor.contentSize.height - editor.bounds.height)
        }
        let originalOffset = editor.contentOffset
        let originalFont = editor.font
        let originalSelection = editor.selectedRange
        let sources = ChatSendFlightSources()
        sources.register(anchor, id: .text)
        let capture = try #require(sources.capture(in: surface, ids: [.text]).first)
        let editorFrame = editor.convert(editor.bounds, to: surface)
        #expect(capture.frame.minY >= editorFrame.minY - 1)
        #expect(capture.frame.maxY <= editorFrame.maxY + 1)
        #expect(capture.frame.height <= editor.bounds.height + 1)
        #expect(editor.contentOffset == originalOffset)
        #expect(editor.font == originalFont)
        #expect(editor.selectedRange == originalSelection)
        #expect(editor.backgroundColor == .white)
        if longDraft {
            #expect(capture.contentVerticalPosition > 0.95)
        } else {
            #expect(capture.frame.width < editor.bounds.width / 2)
        }
    }

    @Test("来源宿主执行真实内容任务并保留完整图片与可见裁切")
    func hostedSourceKeepsLiveStateAndFullSnapshot() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        let sources = ChatSendFlightSources()
        let sourceID = ChatSendPresentationSource.image(UUID())
        let prepared = PreparationFlag()
        let canvas = ScrollView(.horizontal) {
            ChatSendContentSource(id: sourceID) {
                PreparedSourceContent(flag: prepared)
            }
            .frame(width: 160, height: 40)
        }
        .frame(width: 80, height: 40)
        .environment(\.chatSendFlightSources, sources)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        let host = UIHostingController(rootView: canvas)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        host.view.addSubview(surface)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        var capture: ChatSendFlightCapture?
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
            capture = sources.capture(in: surface, ids: [sourceID]).first
            if prepared.didPrepare, capture != nil { break }
        }
        #expect(prepared.didPrepare)
        #expect(prepared.sizeCategory == .accessibilityExtraExtraExtraLarge)
        let captured = try #require(capture)
        let fullFrame = try #require(captured.sourceContentFrame)
        #expect(abs(fullFrame.width - 160) < 1)
        #expect(captured.frame.width <= 81)
        #expect(captured.content.bounds.width > captured.frame.width)
    }
}

@MainActor
private final class PreparationFlag {
    var didPrepare = false
    var sizeCategory: ContentSizeCategory?
}

@MainActor
private struct PreparedSourceContent: View {
    let flag: PreparationFlag
    @Environment(\.sizeCategory) private var sizeCategory
    @State private var prepared = false

    var body: some View {
        Color.blue.overlay {
            Text(prepared ? "就绪" : "准备中").font(.caption)
        }
        .task {
            prepared = true
            flag.didPrepare = true
            flag.sizeCategory = sizeCategory
        }
    }
}
