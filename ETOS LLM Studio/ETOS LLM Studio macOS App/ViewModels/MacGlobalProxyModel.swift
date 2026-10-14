import Combine
import ETOSCore
import Foundation

@MainActor
final class MacGlobalProxyModel: ObservableObject {
    @Published var draft = NetworkProxyConfiguration()
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published var error: String?
    private var original = NetworkProxyConfiguration()
    private var loading: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private var loadID = UUID()

    var canEdit: Bool { isLoaded && !isLoading && !isSaving && !isSuspended && AppLockManager.shared.state != .locked }

    func reload() {
        guard !isSaving, !isSuspended, AppLockManager.shared.state != .locked else { return }
        let previous = loading
        previous?.cancel(); loadID = UUID(); epoch = UUID()
        let id = loadID, epoch = epoch
        isLoading = true; error = nil
        loading = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await NetworkProxyConfigurationLibrary.shared.snapshot()
                guard let self, !Task.isCancelled, loadID == id, self.epoch == epoch, !isSuspended else { return }
                original = snapshot; draft = snapshot; isLoaded = true; isLoading = false
            } catch {
                guard let self, !Task.isCancelled, loadID == id, self.epoch == epoch else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }

    func save() {
        guard canEdit else { return }
        let draft = draft, original = original, epoch = epoch
        isSaving = true; error = nil
        writing = Task { [weak self] in
            defer {
                if let self {
                    isSaving = false
                    if !isSuspended && !isLoaded { reload() }
                }
            }
            do {
                let saved = try await NetworkProxyConfigurationLibrary.shared.save(draft, original: original)
                guard let self, self.epoch == epoch, !isSuspended else { return }
                self.original = saved; self.draft = saved
                self.epoch = UUID()
            } catch {
                guard let self, self.epoch == epoch, !isSuspended else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func suspend() {
        isSuspended = true; epoch = UUID(); loadID = UUID(); loading?.cancel()
        isLoading = false; isLoaded = false
        draft = NetworkProxyConfiguration(); original = NetworkProxyConfiguration(); error = nil
    }

    func resume() { isSuspended = false }

    func waitForPendingWrites() async {
        await writing?.value
        await loading?.value
    }
}
