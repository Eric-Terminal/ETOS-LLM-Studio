import Combine
import ETOSCore
import Foundation

@MainActor
final class MacAchievementModel: ObservableObject {
    @Published private(set) var entries: [AchievementJournalEntry] = []
    private var loadTask: Task<Void, Never>?
    private var changes: AnyCancellable?

    init() {
        changes = NotificationCenter.default.publisher(for: AchievementCenter.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { AchievementCenter.journalSnapshot() }.value
            guard !Task.isCancelled else { return }
            self?.entries = result
        }
    }

    deinit { loadTask?.cancel() }
}
