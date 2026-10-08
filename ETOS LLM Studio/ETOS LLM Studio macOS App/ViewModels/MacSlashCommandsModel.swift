import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSlashCommandsModel: ObservableObject {
    @Published private(set) var catalog: MacSlashCommandCatalog?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = true
    @Published private(set) var epoch = UUID()
    @Published private(set) var revision = UUID()
    @Published var error: String?
    private var loading: Task<Void, Never>?
    private var writing: Task<Void, Error>?
    private var loadID = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var observesLanguage = false
    let actions = MacSlashCommandActions()
    var canWrite: Bool { !isSuspended && !isLoading && !isWorking && catalog != nil && AppLockManager.shared.state != .locked }

    init() {
        actions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        for name in [CustomChatSlashCommandLibrary.didChangeNotification, CustomChatSlashCommandStore.didChangeNotification,
                     AppConfigStore.persistentStoreDidLoadNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        }
    }

    func resume() {
        guard isSuspended else { return }
        if !observesLanguage {
            observesLanguage = true
            AppConfigStore.shared.$appLanguage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] language in
                AppLanguageRuntime.apply(rawValue: language); self?.reload()
            }.store(in: &subscriptions)
        }
        isSuspended = false; epoch = UUID(); actions.resume(); reload()
    }
    func suspend() { isSuspended = true; epoch = UUID(); loadID = UUID(); revision = UUID(); loading?.cancel(); catalog = nil; actions.suspend() }
    func waitForPendingOperations() async { await loading?.value; _ = try? await writing?.value; await actions.waitForCompletion() }

    func reload() {
        guard !isSuspended, !isWorking else { return }
        let previous = loading
        previous?.cancel(); loadID = UUID()
        let expectedLoad = loadID, expectedEpoch = epoch
        isLoading = true
        loading = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await CustomChatSlashCommandLibrary.shared.snapshot()
                let prepared = await Task.detached(priority: .utility) { MacSlashCommandCatalog(snapshot) }.value
                guard let self, !Task.isCancelled, epoch == expectedEpoch, loadID == expectedLoad, !isSuspended else { return }
                catalog = prepared; isLoading = false; revision = UUID(); error = nil
            } catch {
                guard let self, !Task.isCancelled, epoch == expectedEpoch, loadID == expectedLoad else { return }
                isLoading = false; self.error = error.localizedDescription
            }
        }
    }

    func replace(_ commands: [CustomChatSlashCommand], original: CustomChatSlashCommandSnapshot, expectedEpoch: UUID) async throws {
        guard canWrite, epoch == expectedEpoch else { throw MacMemoryWriteError.busy }
        isWorking = true; error = nil
        let task = Task { [weak self] in
            await AppConfigStore.shared.flushPendingWrites()
            let saved = try await CustomChatSlashCommandLibrary.shared.replace(commands, original: original)
            let prepared = await Task.detached(priority: .utility) { MacSlashCommandCatalog(saved) }.value
            guard let self, epoch == expectedEpoch, !isSuspended else { return }
            catalog = prepared; revision = UUID()
        }
        writing = task
        defer {
            writing = nil; isWorking = false
            if !isSuspended { reload() }
        }
        try await task.value
    }

    func delete(_ command: CustomChatSlashCommand, original: CustomChatSlashCommandSnapshot, expectedEpoch: UUID) async throws {
        let replacement = await Task.detached { original.commands.filter { $0.id != command.id } }.value
        try await replace(replacement, original: original, expectedEpoch: expectedEpoch)
    }
}
