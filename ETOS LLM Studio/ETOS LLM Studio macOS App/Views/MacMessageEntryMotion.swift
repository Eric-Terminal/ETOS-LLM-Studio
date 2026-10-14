import ETOSCore
import SwiftUI

@MainActor
struct MacMessageEntryMotion: ViewModifier {
    nonisolated static let coordinateSpace = "mac-chat-message-entry"
    @ObservedObject var model: MacSendMotionModel
    let messageID: UUID
    let sessionID: UUID?
    let viewport: CGRect
    let isActive: Bool
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macChatIsUserScrolling) private var isUserScrolling
    @State private var frame = CGRect.zero
    @State private var translation = CGSize.zero
    @State private var scale = 1.0
    @State private var opacity = 1.0
    @State private var batchID: UUID?
    @State private var generation = UUID()
    @State private var launch: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: {
                frame = $0
                startIfNeeded()
            }
            .offset(translation).scaleEffect(scale, anchor: .bottom).opacity(opacity)
            .scrollTransition(topLeading: .animated(.smooth(duration: 0.4)),
                bottomTrailing: .animated(.spring(response: settings.scrollResponse, dampingFraction: settings.scrollDamping))) { [settings = settings, interacting = isUserScrolling, reduce = reduceMotion] content, phase in
                content.offset(y: settings.scrollTranslation(phase: phase.value, interacting: interacting, reduceMotion: reduce))
            }
            .onChange(of: model.revision) { _, _ in
                if batchID != model.batch?.id { reset() }
                startIfNeeded()
            }
            .onChange(of: viewport) { _, _ in startIfNeeded() }
            .onChange(of: isActive) { _, active in if !active { reset() } }
            .onChange(of: reduceMotion) { _, reduce in if reduce { reset() } }
            .onChange(of: configuration.chatSendAnimationEnabled) { _, enabled in if !enabled { reset() } }
            .onDisappear { reset() }
    }

    private var settings: MacChatMotionSettings { MacChatMotionSettings(configuration) }

    private func startIfNeeded() {
        guard isActive, !reduceMotion, !isUserScrolling, settings.sendEnabled,
              let offset = model.claim(messageID, sessionID: sessionID, target: frame, viewport: viewport) else { return }
        launch?.cancel()
        let generation = UUID(); self.generation = generation
        batchID = model.batch?.id
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { translation = offset; scale = 0.96; opacity = 0.6 }
        let response = settings.sendResponse, damping = settings.sendDamping
        launch = Task {
            // 等布局接收起点后再交给系统弹簧，不隐藏或复制真正的消息视图。
            await Task.yield()
            guard !Task.isCancelled, self.generation == generation else { return }
            withAnimation(.spring(response: response, dampingFraction: damping)) {
                translation = .zero; scale = 1; opacity = 1
            }
        }
    }

    private func reset() {
        launch?.cancel(); launch = nil; generation = UUID(); batchID = nil
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { translation = .zero; scale = 1; opacity = 1 }
    }
}

extension MacChatMotionSettings {
    @MainActor init(_ configuration: AppConfigStore) {
        self.init(scrollEnabled: configuration.chatScrollAnimationEnabled, scrollOffset: configuration.chatScrollAnimationOffset,
            scrollResponse: configuration.chatScrollAnimationSpringResponse, scrollDamping: configuration.chatScrollAnimationSpringDamping,
            sendEnabled: configuration.chatSendAnimationEnabled, sendResponse: configuration.chatSendAnimationSpringResponse,
            sendDamping: configuration.chatSendAnimationSpringDamping)
    }
}
