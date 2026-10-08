import AppKit
import Combine
import ETOSCore

@MainActor
final class MacAppearanceModel: ObservableObject {
    @Published private(set) var catalog: MacAppearanceCatalog?
    @Published private(set) var activeProfile = ChatAppearanceProfile.defaultProfile
    @Published private(set) var renderRevision = UUID()
    @Published private(set) var epoch = UUID()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSuspended = true
    @Published var error: String?
    private var loading: Task<Void, Never>?
    private var writing: Task<Bool, Never>?
    private var boundary: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    var canEdit: Bool { catalog != nil && !isLoading && !isSaving && !isSuspended && AppLockManager.shared.state != .locked }

    func start() {
        guard !started else { return }; started = true
        for name in [ChatAppearanceConfigurationLibrary.didChangeNotification, .snapshotRestoreDidFinish,
                     AppConfigStore.persistentStoreDidLoadNotification, NSApplication.didBecomeActiveNotification,
                     .NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        }
        AppConfigStore.shared.$appLanguage.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
    }

    func reload() {
        guard !isSuspended, !isSaving, AppLockManager.shared.state != .locked else { return }
        let previous = loading; previous?.cancel(); boundary?.cancel()
        let old = catalog, epoch = epoch
        isLoading = true
        loading = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let configuration = try await ChatAppearanceConfigurationLibrary.shared.snapshot()
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let prepared = MacAppearanceCatalog(configuration)
                    return (prepared, old?.configuration != configuration, old?.activeProfile != prepared.activeProfile)
                }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !isSuspended, self.epoch == epoch, !Task.isCancelled else { return }
                if prepared.1 { self.epoch = UUID() }
                apply(prepared.0, refreshText: prepared.2); isLoading = false
            } catch {
                guard let self, !isSuspended, self.epoch == epoch, !Task.isCancelled else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }

    func save(_ change: MacAppearanceChange, original: ChatAppearanceProfileConfiguration, expectedEpoch: UUID) async -> Bool {
        guard canEdit, epoch == expectedEpoch else { return false }
        isSaving = true; error = nil; boundary?.cancel()
        let previous = loading; previous?.cancel()
        let task = Task { [weak self] () -> Bool in
            await previous?.value
            defer {
                if let self { isSaving = false; if !isSuspended && catalog == nil { reload() } }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let updated = try change.applying(to: original)
                    let saved = try await ChatAppearanceConfigurationLibrary.shared.save(updated, original: original)
                    return MacAppearanceCatalog(saved)
                }
                let saved = try await worker.value
                guard let self, !isSuspended, epoch == expectedEpoch else { return false }
                epoch = UUID(); apply(saved, refreshText: true)
                return true
            } catch {
                guard let self, !isSuspended, epoch == expectedEpoch else { return false }
                self.error = error.localizedDescription
                if let catalog { scheduleBoundary(catalog.nextBoundary) }
                return false
            }
        }
        writing = task
        return await task.value
    }

    private func apply(_ catalog: MacAppearanceCatalog, refreshText: Bool) {
        self.catalog = catalog; activeProfile = catalog.activeProfile; error = nil
        if refreshText { renderRevision = UUID() }
        scheduleBoundary(catalog.nextBoundary)
    }

    private func scheduleBoundary(_ date: Date?) {
        boundary?.cancel(); boundary = nil
        guard !isSuspended, let date else { return }
        let delay = max(1, min(date.timeIntervalSinceNow, 24 * 60 * 60))
        boundary = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.reload()
        }
    }

    func suspend() {
        isSuspended = true; epoch = UUID(); isLoading = false
        loading?.cancel(); boundary?.cancel(); catalog = nil; error = nil
        activeProfile = .defaultProfile; renderRevision = UUID()
    }
    func resume() {
        let needsLoad = isSuspended || catalog == nil
        isSuspended = false
        if needsLoad { reload() }
    }
    func waitForPendingOperations() async { _ = await writing?.value; await loading?.value }
}
