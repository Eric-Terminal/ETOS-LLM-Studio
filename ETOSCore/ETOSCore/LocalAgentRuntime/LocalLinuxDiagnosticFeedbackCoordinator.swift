import Foundation
import Combine

@MainActor
final class LocalLinuxDiagnosticFeedbackCoordinator: ObservableObject {
    static let shared = LocalLinuxDiagnosticFeedbackCoordinator()

    struct Prompt: Identifiable {
        enum Kind {
            case consent
            case sent(Int)
            case failed(String)
        }
        let id = UUID()
        let offer: LocalLinuxDiagnosticFeedbackOffer
        let kind: Kind
    }

    private struct Presenter {
        let id: UUID
        let priority: Int
        var blocked: Bool
    }

    @Published private(set) var prompt: Prompt?
    @Published private(set) var isSending = false
    @Published private(set) var presenterID: UUID?
    private var presenters: [Presenter] = []
    private var queue: [LocalLinuxDiagnosticFeedbackOffer] = []
    private var currentOffer: LocalLinuxDiagnosticFeedbackOffer?
    private var pendingDraft: FeedbackDraft?
    private let buffer: LocalLinuxDiagnosticFeedbackBuffer
    private let submit: @MainActor (FeedbackDraft) async throws -> Int
    private let runtimeSnapshot: @Sendable () async -> LocalLinuxRuntimeSnapshot

    init(
        buffer: LocalLinuxDiagnosticFeedbackBuffer = .shared,
        runtimeSnapshot: (@Sendable () async -> LocalLinuxRuntimeSnapshot)? = nil,
        submit: @escaping @MainActor (FeedbackDraft) async throws -> Int = { draft in
            try await FeedbackService.shared.submit(draft: draft).issueNumber
        }
    ) {
        self.buffer = buffer
        self.runtimeSnapshot = runtimeSnapshot ?? {
            await LocalLinuxRuntimeController.shared.snapshot()
        }
        self.submit = submit
    }

    func offer(_ offer: LocalLinuxDiagnosticFeedbackOffer) {
        queue.append(offer)
        presentNextIfNeeded()
    }

    func registerPresenter(id: UUID, priority: Int, blocked: Bool) {
        if let index = presenters.firstIndex(where: { $0.id == id }) {
            presenters[index].blocked = blocked
        } else {
            presenters.append(Presenter(id: id, priority: priority, blocked: blocked))
        }
        refreshPresenter()
    }

    func unregisterPresenter(id: UUID) {
        presenters.removeAll { $0.id == id }
        refreshPresenter()
    }

    private func refreshPresenter() {
        // 终端可能在 sheet 中，也可能在聊天页内嵌；只让最上层的可见宿主弹窗。
        // 顶层正在显示其他错误时暂缓，不把弹窗转交给被遮挡的根页面。
        let top = presenters.enumerated().max { lhs, rhs in
            (lhs.element.priority, lhs.offset) < (rhs.element.priority, rhs.offset)
        }?.element
        presenterID = top?.blocked == false ? top?.id : nil
    }

    @discardableResult
    func dismiss(promptID: UUID) -> Task<Void, Never>? {
        guard let prompt, prompt.id == promptID else { return nil }
        let jobID = prompt.offer.id
        self.prompt = nil
        currentOffer = nil
        pendingDraft = nil
        // 等系统先关闭当前 alert，再呈现其他任务的询问。
        return Task { [weak self, buffer] in
            await buffer.discard(jobID: jobID)
            await Task.yield()
            self?.presentNextIfNeeded()
        }
    }

    @discardableResult
    func send(promptID: UUID) -> Task<Void, Never>? {
        guard let prompt, prompt.id == promptID, !isSending else { return nil }
        switch prompt.kind {
        case .sent: return nil
        case .consent, .failed: break
        }
        self.prompt = nil
        isSending = true
        // 页面退出不取消已获同意的发送；工单仍会保存在反馈助手中。
        return Task { await performSubmission(offer: prompt.offer) }
    }

    private func performSubmission(offer: LocalLinuxDiagnosticFeedbackOffer) async {
        defer {
            isSending = false
            presentNextIfNeeded()
        }
        do {
            if pendingDraft == nil {
                let runtime = await runtimeSnapshot()
                pendingDraft = try await buffer.makeDraft(jobID: offer.id, runtime: runtime)
            }
            guard let pendingDraft else {
                currentOffer = nil
                presentNextIfNeeded()
                return
            }
            let issueNumber = try await submit(pendingDraft)
            self.pendingDraft = nil
            self.prompt = Prompt(offer: offer, kind: .sent(issueNumber))
        } catch {
            // 网络失败保留已经同意的同一份草稿；重试不会加入之后产生的新事件。
            self.prompt = Prompt(offer: offer, kind: .failed(error.localizedDescription))
        }
    }

    private func presentNextIfNeeded() {
        guard currentOffer == nil, !isSending, !queue.isEmpty else { return }
        let offer = queue.removeFirst()
        currentOffer = offer
        prompt = Prompt(offer: offer, kind: .consent)
    }
}
