import Foundation

/// 坐标沿用 ScrollGeometry 的 contentOffset，保留安全区和工具栏的实际滚动边界。
struct MacChatViewport: Equatable, Sendable {
    var offset: CGFloat = 0
    var minimum: CGFloat = 0
    var maximum: CGFloat = 0
    var height: CGFloat = 0

    init() {}
    init(offset: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, visibleHeight: CGFloat,
         topInset: CGFloat, bottomInset: CGFloat) {
        self.offset = offset
        minimum = -topInset
        maximum = max(minimum, contentHeight + bottomInset - containerHeight)
        height = visibleHeight
    }

    var distanceToTop: CGFloat { max(0, offset - minimum) }
    var distanceToBottom: CGFloat { max(0, maximum - offset) }
    var canGoUp: Bool { height > 0 && distanceToTop > 1 }
    var canGoDown: Bool { height > 0 && distanceToBottom > 1 }

    func page(down: Bool) -> CGFloat {
        // 保留少量重叠，长段落翻页后仍能接着读；小窗口也不会跨过整屏。
        let step = height * 0.9
        return min(maximum, max(minimum, offset + (down ? step : -step)))
    }
}

struct MacChatFollowState {
    private(set) var followsLatest = true
    private(set) var isInteracting = false
    private(set) var viewport = MacChatViewport()

    mutating func observe(_ next: MacChatViewport) -> Bool {
        let layoutChanged = viewport.maximum != next.maximum || viewport.height != next.height || viewport.minimum != next.minimum
        viewport = next
        // 内容变长不代表用户离开底部；只有用户手势和显式导航能解除跟随。
        return followsLatest && !isInteracting && layoutChanged && next.height > 0
    }

    mutating func interaction(_ active: Bool) -> Bool {
        let wasInteracting = isInteracting
        isInteracting = active
        if active { followsLatest = false }
        else if wasInteracting { followsLatest = viewport.distanceToBottom < 44 }
        return wasInteracting && !active && followsLatest
    }

    mutating func navigate(toLatest: Bool) {
        isInteracting = false
        followsLatest = toLatest
    }
}

struct MacChatMotionSettings: Equatable, Sendable {
    let scrollEnabled: Bool
    let scrollOffset: Double
    let scrollResponse: Double
    let scrollDamping: Double
    let sendEnabled: Bool
    let sendResponse: Double
    let sendDamping: Double

    init(scrollEnabled: Bool, scrollOffset: Double, scrollResponse: Double, scrollDamping: Double,
         sendEnabled: Bool, sendResponse: Double, sendDamping: Double) {
        self.scrollEnabled = scrollEnabled
        self.scrollOffset = min(60, max(4, scrollOffset))
        self.scrollResponse = min(1, max(0.15, scrollResponse))
        self.scrollDamping = min(0.95, max(0.1, scrollDamping))
        self.sendEnabled = sendEnabled
        self.sendResponse = min(0.8, max(0.2, sendResponse))
        self.sendDamping = min(1, max(0.4, sendDamping))
    }

    func scrollTranslation(phase: CGFloat, interacting: Bool, reduceMotion: Bool) -> CGFloat {
        scrollEnabled && interacting && !reduceMotion ? phase * CGFloat(scrollOffset) : 0
    }
}
