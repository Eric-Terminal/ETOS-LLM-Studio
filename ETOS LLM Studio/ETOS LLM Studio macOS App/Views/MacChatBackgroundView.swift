import AppKit
import AVFoundation
import ETOSCore
import SwiftUI

struct MacChatBackgroundView: View {
    @ObservedObject var model: MacBackgroundModel
    @ObservedObject private var configuration = AppConfigStore.shared

    var body: some View {
        Group {
            if configuration.enableBackground, let file = model.selectedFile {
                GeometryReader { geometry in
                    Group {
                        if file.isVideo {
                            MacBackgroundVideoSurface(model: model.playback, fills: configuration.backgroundContentMode != "fit")
                        } else {
                            MacBackgroundImage(file: file, size: geometry.size, fills: configuration.backgroundContentMode != "fit")
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .blur(radius: configuration.backgroundBlur)
                    .opacity(configuration.backgroundOpacity)
                    .clipped()
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .background { MacBackgroundWindowVisibility { model.setVisible($0) } }
        .onDisappear { model.setVisible(false) }
    }
}

private struct MacBackgroundImage: View {
    let file: MacBackgroundFile
    let size: CGSize
    let fills: Bool
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?
    private struct Request: Equatable {
        let file: MacBackgroundFile
        let target: DisplayImageTarget
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
                    .frame(width: size.width, height: size.height)
            }
        }
        .task(id: Request(file: file, target: DisplayImageTarget(size: size, scale: scale, fillsBounds: fills))) {
            image = nil
            let loaded = await DisplayImageLoader.shared.image(at: file.url,
                target: DisplayImageTarget(size: size, scale: scale, fillsBounds: fills))
            guard !Task.isCancelled else { return }
            image = loaded?.image
        }
    }
}

private struct MacBackgroundVideoSurface: View {
    @ObservedObject var model: MacBackgroundPlayback
    let fills: Bool
    var body: some View { MacBackgroundPlayerLayer(player: model.player, fills: fills) }
}

private struct MacBackgroundPlayerLayer: NSViewRepresentable {
    let player: AVQueuePlayer?
    let fills: Bool
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = AVPlayerLayer()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer as? AVPlayerLayer else { return }
        layer.player = player
        layer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view.layer as? AVPlayerLayer)?.player = nil }
}

/// 使用窗口事件判断最小化和遮挡；切换设置窗口不等于整个 App 进入后台。
private struct MacBackgroundWindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = changed; view.publishVisibility() }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var previous: Bool?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] event in
                        let closing = event.name == NSWindow.willCloseNotification
                        Task { @MainActor [weak self, weak window] in
                            guard let self, let window, self.window === window else { return }
                            if closing { publish(false) } else { publishVisibility() }
                        }
                    })
                }
            }
            publishVisibility()
        }
        func publishVisibility() {
            publish(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
        }
        private func publish(_ visible: Bool) {
            guard previous != visible, let changed else { return }
            previous = visible
            // 避免 NSView 更新栈内同步修改 SwiftUI 观察对象；排队结果需核对最新可见状态。
            DispatchQueue.main.async { [weak self] in
                guard self?.previous == visible else { return }
                changed(visible)
            }
        }
        func stop() { stopObserving(); previous = nil; changed = nil }
        private func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
    }
}
