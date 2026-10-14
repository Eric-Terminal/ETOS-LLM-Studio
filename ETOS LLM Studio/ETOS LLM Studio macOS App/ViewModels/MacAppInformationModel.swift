import Combine
import ETOSCore
import Foundation

struct MacUpdateTimelinePresentation: Sendable {
    struct Commit: Identifiable, Sendable {
        let value: UpdateTimelineCommit
        let text: MacPreparedMessageText
        let headline: String
        let shortOID: String
        var id: String { value.oid }
    }
    let commits: [Commit]
    let summary: MacPreparedMessageText?
    let allowsSummary: Bool

    init(_ state: UpdateTimelineState) {
        commits = state.timelineCommits.map { .init(value: $0, text: MacPreparedMessageText($0.fullMessage, markdown: true), headline: $0.displayHeadline, shortOID: $0.shortOID) }
        summary = state.summaryText.map { MacPreparedMessageText($0, markdown: true) }
        allowsSummary = state.allowsSummary
    }
}

@MainActor
final class MacAppInformationModel: ObservableObject {
    static let shared = MacAppInformationModel()
    let feedback = FeedbackService(initialTickets: [])
    @Published private(set) var refreshingFeedbackOnLaunch = false
    @Published private(set) var updates: UpdateTimelineManager?
    @Published private(set) var timeline: MacUpdateTimelinePresentation?
    @Published private(set) var working = false
    @Published var preview: OfficialDataSyncPreview?
    @Published var notice: String?
    private var launchTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var epoch = UUID()
    private var suspension: Task<Void, Never>?
    private var wantsActive = false

    func activate() {
        wantsActive = true
        if let suspension {
            Task { [weak self] in
                await suspension.value
                if self?.wantsActive == true { self?.activate() }
            }
            return
        }
        guard launchTask == nil else { return }
        let epoch = epoch
        launchTask = Task { [weak self] in
            let updates = await UpdateTimelineManager.makeWithPreparedCache()
            guard let self, self.epoch == epoch, !Task.isCancelled else { await updates.suspendAndFlush(); return }
            self.updates = updates
            subscription = updates.$state.receive(on: DispatchQueue.main).sink { [weak self] state in self?.prepare(state) }
            updates.activateOnLaunchIfNeeded()
            await AnnouncementManager.shared.checkAnnouncement()
            guard !Task.isCancelled else { return }
            refreshingFeedbackOnLaunch = true
            await feedback.refreshTicketsOnLaunch()
            refreshingFeedbackOnLaunch = false
        }
    }

    func refresh() { perform { [weak self] in await self?.updates?.refresh(forceNetwork: true) } }
    func summarize() { perform { [weak self] in await self?.updates?.generateSummary() } }
    func clearUpdates() { updates?.clearPersistentCache() }

    func prepareOfficialData() {
        perform { [weak self] in
            do {
                let preview = try await ConfigLoader.prepareOfficialDataSync()
                if !Task.isCancelled { self?.preview = preview }
            } catch { if !Task.isCancelled { self?.notice = error.localizedDescription } }
        }
    }

    func applyOfficialData(_ preview: OfficialDataSyncPreview) {
        perform { [weak self] in
            let result = await ConfigLoader.applyOfficialDataSync(preview)
            self?.preview = nil
            self?.notice = result.isAlreadyRunning ? NSLocalizedString("官方数据正在同步，请稍后再试。", comment: "")
                : result.isComplete ? NSLocalizedString("同步完成", comment: "")
                : result.failureMessages.first ?? NSLocalizedString("部分官方数据处理失败，请检查网络后重试。", comment: "")
        }
    }

    func suspend() async {
        wantsActive = false
        if let suspension { await suspension.value; return }
        let task = Task { await finishSuspending() }
        suspension = task
        await task.value
        suspension = nil
    }

    private func finishSuspending() async {
        epoch = UUID(); preview = nil
        launchTask?.cancel(); operation?.cancel(); preparation?.cancel(); subscription = nil
        await launchTask?.value; await operation?.value; await preparation?.value
        await updates?.suspendAndFlush()
        launchTask = nil; operation = nil; updates = nil; timeline = nil; working = false
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard !working, updates != nil else { return }
        working = true; notice = nil
        operation = Task { [weak self] in
            await action()
            self?.working = false
        }
    }

    private func prepare(_ state: UpdateTimelineState) {
        preparation?.cancel()
        preparation = Task { [weak self] in
            let value = await Task.detached(priority: .utility) { MacUpdateTimelinePresentation(state) }.value
            if !Task.isCancelled { self?.timeline = value }
        }
    }
}
