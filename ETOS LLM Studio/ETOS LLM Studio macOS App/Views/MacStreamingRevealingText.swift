import ETOSCore
import SwiftUI

struct MacStreamingRevealingText: View {
    let prepared: MacStreamingReveal
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating || reduceMotion)) { timeline in
            prepared.text.textRenderer(MacStreamingTextRenderer(
                now: timeline.date.timeIntervalSinceReferenceDate,
                mode: ChatStreamingDisplayMode(rawValue: configuration.chatStreamingDisplayMode) ?? .defaultMode,
                finishImmediately: reduceMotion || timeline.date.timeIntervalSinceReferenceDate >= prepared.endsAt))
        }
        .task(id: prepared.id) {
            let remaining = prepared.endsAt - Date.timeIntervalSinceReferenceDate
            guard !reduceMotion, remaining > 0 else { animating = false; return }
            animating = true
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            animating = false
        }
        .onDisappear { animating = false }
    }
}

private struct MacStreamingTextRenderer: TextRenderer {
    let now: TimeInterval
    let mode: ChatStreamingDisplayMode
    let finishImmediately: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // 只修改新增字形的不透明度，行高和滚动位置始终使用最终文字布局。
        for line in layout {
            for run in line {
                var drawing = context
                if !finishImmediately, let attribute = run[MacStreamingRevealAttribute.self] {
                    let elapsed = now - attribute.startedAt - attribute.stagger * mode.textRevealStaggerWindow
                    let progress = min(1, max(0, elapsed / mode.textRevealDuration))
                    drawing.opacity *= progress * progress * (3 - 2 * progress)
                }
                drawing.draw(run)
            }
        }
    }
}
