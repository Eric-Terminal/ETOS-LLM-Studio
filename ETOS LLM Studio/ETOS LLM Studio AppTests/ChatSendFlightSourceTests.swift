import CoreGraphics
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
        let editor = CaptureTrackingTextView(frame: CGRect(x: 20, y: 80, width: 260, height: 90))
        let font = try #require(UIFont(name: "Georgia-Italic", size: 17))
        let text = NSMutableAttributedString(
            string: longDraft ? String(repeating: "前面的红色草稿不应进入快照。\n", count: 100) : "e\u{301} 🟨 短句",
            attributes: [.font: font, .foregroundColor: longDraft ? UIColor.red : UIColor.black]
        )
        if longDraft {
            text.append(NSAttributedString(
                string: String(repeating: "正在阅读的绿色末尾\n", count: 8),
                attributes: [.font: font, .foregroundColor: UIColor.green]
            ))
        }
        editor.attributedText = text
        editor.backgroundColor = .white
        editor.tintColor = .magenta
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
        editor.becomeFirstResponder()
        editor.layoutIfNeeded()
        editor.selectedRange = NSRange(location: longDraft ? text.length - 8 : 0, length: 1)
        if longDraft {
            editor.contentOffset.y = max(0, editor.contentSize.height - editor.bounds.height)
        }
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            editor.layoutIfNeeded()
            if selectionDecorationLayers(in: editor).contains(where: { !$0.isHidden && !$0.bounds.isEmpty }) { break }
        }
        let originalOffset = editor.contentOffset
        let originalFont = try #require(editor.font)
        #expect(originalFont.fontName == font.fontName)
        let originalSelection = editor.selectedRange
        let originalBackgroundColor = editor.backgroundColor
        let originalTintColor = editor.tintColor
        let originalIsOpaque = editor.isOpaque
        let originalLayerBackground = editor.layer.backgroundColor
        let originalTintChanges = editor.tintChanges
        let selectionLayers = selectionDecorationLayers(in: editor)
        try #require(selectionLayers.contains { !$0.isHidden && !$0.bounds.isEmpty })
        let selectionHiddenStates = selectionLayers.map(\.isHidden)
        let sources = ChatSendFlightSources()
        sources.register(anchor, id: .text)
        let captures = sources.capture(in: surface, ids: [.text])
        #expect(editor.backgroundColor == originalBackgroundColor)
        #expect(editor.tintColor == originalTintColor)
        #expect(editor.isOpaque == originalIsOpaque)
        #expect(editor.layer.backgroundColor == originalLayerBackground)
        #expect(editor.tintChanges == originalTintChanges)
        #expect(editor.screenSnapshotCalls == 0)
        #expect(selectionLayers.map(\.isHidden) == selectionHiddenStates)
        let capture = try #require(captures.first)
        let editorFrame = editor.convert(editor.bounds, to: surface)
        #expect(capture.frame.minY >= editorFrame.minY - 1)
        #expect(capture.frame.maxY <= editorFrame.maxY + 1)
        #expect(capture.frame.height <= editor.bounds.height + 1)
        #expect(editor.contentOffset == originalOffset)
        #expect(editor.font == originalFont)
        #expect(editor.selectedRange == originalSelection)
        #expect(editor.isFirstResponder)
        let pixels = try imagePixelCounts(capture)
        #expect(pixels.transparent > 20)
        #expect(pixels.ink > 20)
        #expect(pixels.magenta == 0)
        if longDraft {
            #expect(capture.contentVerticalPosition > 0.95)
            #expect(pixels.green > 20)
            #expect(pixels.red == 0)
        } else {
            #expect(capture.frame.width < editor.bounds.width)
            #expect(pixels.chromatic > 20)
        }
    }

    @Test("真实单行输入保留组合字形和 emoji，光标与范围选区不进入透明快照", arguments: [false, true])
    func textFieldCaptureKeepsGlyphsWithoutEditingDecorations(rangedSelection: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let host = UIViewController()
        window.rootViewController = host
        let editor = UITextField(frame: CGRect(x: 20, y: 80, width: 260, height: 50))
        let font: UIFont = try #require(UIFont(name: "Georgia-Italic", size: 20))
        editor.font = font
        editor.textColor = .black
        editor.text = "e\u{301} 🟨 组合字形"
        editor.backgroundColor = .white
        editor.tintColor = .magenta
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
        editor.becomeFirstResponder()
        let start = editor.beginningOfDocument
        let end = rangedSelection ? editor.endOfDocument : start
        editor.selectedTextRange = editor.textRange(from: start, to: end)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            editor.layoutIfNeeded()
            if selectionDecorationLayers(in: editor).contains(where: { !$0.isHidden && !$0.bounds.isEmpty }) { break }
        }
        let originalSelection = try #require(editor.selectedTextRange)
        let originalFont = editor.font
        let originalText = editor.attributedText
        let originalBackground = editor.backgroundColor
        let originalLayerBackground = editor.layer.backgroundColor
        let originalTint = editor.tintColor
        let originalOpaque = editor.isOpaque
        let layers = selectionDecorationLayers(in: editor)
        try #require(layers.contains { !$0.isHidden && !$0.bounds.isEmpty })
        let hiddenStates = layers.map(\.isHidden)
        let sources = ChatSendFlightSources()
        sources.register(anchor, id: .text)
        let capture = try #require(sources.capture(in: surface, ids: [.text]).first)
        let pixels = try imagePixelCounts(capture)
        #expect(pixels.transparent > 20)
        #expect(pixels.ink > 20)
        #expect(pixels.chromatic > 20)
        #expect(pixels.magenta == 0)
        #expect(editor.font == originalFont)
        #expect(editor.attributedText == originalText)
        #expect(editor.backgroundColor == originalBackground)
        #expect(editor.layer.backgroundColor == originalLayerBackground)
        #expect(editor.tintColor == originalTint)
        #expect(editor.isOpaque == originalOpaque)
        #expect(layers.map(\.isHidden) == hiddenStates)
        let selection = try #require(editor.selectedTextRange)
        #expect(editor.compare(selection.start, to: originalSelection.start) == .orderedSame)
        #expect(editor.compare(selection.end, to: originalSelection.end) == .orderedSame)
        #expect(editor.isFirstResponder)
    }

    @Test("SwiftUI 实际 TextEditor 的可见排版产生字形像素而不是空白层")
    func swiftUIEditorCaptureContainsLiveGlyphs() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let sources = ChatSendFlightSources()
        let text = String(repeating: "前文不应进入可见快照。\n", count: 80) + String(repeating: "e\u{301} 🟨 末尾字形\n", count: 8)
        let host = UIHostingController(rootView:
            TextEditor(text: .constant(text))
                .font(.custom("Georgia-Italic", size: 19))
                .foregroundStyle(.black)
                .scrollContentBackground(.hidden)
                .frame(width: 260, height: 90)
                .background(ChatSendSourceAnchor(id: .text))
                .environment(\.chatSendFlightSources, sources)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        window.addSubview(surface)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        var mountedEditor: UITextView?
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
            mountedEditor = textView(in: host.view)
            if (mountedEditor?.contentSize.height ?? 0) > 90 { break }
        }
        let editor = try #require(mountedEditor)
        editor.contentOffset.y = max(0, editor.contentSize.height - editor.bounds.height)
        try await Task.sleep(for: .milliseconds(40))
        editor.layoutIfNeeded()
        let originalOffset = editor.contentOffset
        let originalFont = editor.font
        let capture = try #require(sources.capture(in: surface, ids: [.text]).first)
        let pixels = try imagePixelCounts(capture)
        #expect(pixels.transparent > 20)
        #expect(pixels.ink > 20)
        // 只有末尾几行含黄色 emoji，能排除偏移被重复扣除后抓到前文或空白。
        #expect(pixels.chromatic > 20)
        #expect(capture.contentVerticalPosition > 0.95)
        #expect(capture.frame.height <= 91)
        #expect(editor.contentOffset == originalOffset)
        #expect(editor.font == originalFont)
    }

    @Test("来源宿主执行真实内容任务并保留独立标签与可见裁切")
    func hostedSourceKeepsLiveStateAndFullSnapshot() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        let sources = ChatSendFlightSources()
        let sourceID = ChatSendPresentationSource.file(UUID())
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
        // 让捕获层与宿主视图同级，避免直接修改 SwiftUI 管理的子视图树。
        window.addSubview(surface)
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

    private func selectionDecorationLayers(in view: UIView) -> [CALayer] {
        view.interactions.compactMap { $0 as? UITextSelectionDisplayInteraction }.flatMap { interaction in
            [interaction.cursorView.layer, interaction.highlightView.layer] + interaction.handleViews.map(\.layer)
        } + view.subviews.flatMap { selectionDecorationLayers(in: $0) }
    }

    private func textView(in view: UIView) -> UITextView? {
        if let editor = view as? UITextView { return editor }
        for child in view.subviews {
            if let editor = textView(in: child) { return editor }
        }
        return nil
    }

    private func imagePixelCounts(_ capture: ChatSendFlightCapture) throws -> SourcePixelCounts {
        let imageView = try #require(capture.content as? UIImageView)
        let image = try #require(imageView.image?.cgImage)
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        var counts = SourcePixelCounts()
        for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
            let alpha = bytes[offset + 3]
            if alpha == 0 { counts.transparent += 1 }
            if alpha > 8 {
                counts.ink += 1
                if red > green + 30, blue > green + 30 { counts.magenta += 1 }
                if max(red, green, blue) - min(red, green, blue) > 30 { counts.chromatic += 1 }
            }
            if alpha > 120 {
                if red > 100, green < 80, blue < 80 { counts.red += 1 }
                if green > 100, red < 80, blue < 80 { counts.green += 1 }
            }
        }
        return counts
    }
}

private struct SourcePixelCounts {
    var transparent = 0
    var ink = 0
    var magenta = 0
    var chromatic = 0
    var red = 0
    var green = 0
}

@MainActor
private final class CaptureTrackingTextView: UITextView {
    var tintChanges = 0
    var screenSnapshotCalls = 0

    override func tintColorDidChange() {
        tintChanges += 1
        super.tintColorDidChange()
    }

    override func resizableSnapshotView(
        from rect: CGRect,
        afterScreenUpdates afterUpdates: Bool,
        withCapInsets capInsets: UIEdgeInsets
    ) -> UIView? {
        screenSnapshotCalls += 1
        return super.resizableSnapshotView(from: rect, afterScreenUpdates: afterUpdates, withCapInsets: capInsets)
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
