import AppKit
import Combine
import ETOSCore
import UniformTypeIdentifiers

@MainActor
final class MacFontModel: ObservableObject {
    @Published private(set) var catalog: MacFontCatalog?
    @Published private(set) var epoch = UUID()
    @Published private(set) var renderRevision = UUID()
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = true
    @Published private(set) var isImportPanelOpen = false
    @Published var error: String?
    private var loading: Task<Void, Never>?
    private var writing: Task<Bool, Never>?
    private var panel: NSOpenPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    var canEdit: Bool { catalog != nil && !isLoading && !isWorking && !isSuspended && !isImportPanelOpen && AppLockManager.shared.state != .locked }

    func start() {
        guard !started else { return }; started = true
        for name in [Notification.Name.syncFontsUpdated, .snapshotRestoreDidFinish, AppConfigStore.persistentStoreDidLoadNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        }
        let config = AppConfigStore.shared
        config.$fontUseCustomFonts.combineLatest(config.$fontFallbackScope, config.$fontCustomScale, config.$fontLineSpacingEmIOS)
            .dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        config.$appLanguage.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
    }

    func reload() {
        guard !isSuspended, !isWorking, !isImportPanelOpen, AppLockManager.shared.state != .locked else { return }
        let previous = loading; previous?.cancel()
        let old = catalog?.snapshot, epoch = epoch
        isLoading = true
        loading = Task { [weak self] in
            await previous?.value
            do {
                let snapshot = try await FontConfigurationLibrary.shared.snapshot()
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    FontLibrary.preloadRuntimeCache(forceReload: true)
                    return (MacFontCatalog(snapshot), old != snapshot)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.epoch == epoch, !isSuspended, !Task.isCancelled else { return }
                if result.1 { self.epoch = UUID() }
                catalog = result.0; error = nil; isLoading = false; renderRevision = UUID()
            } catch {
                guard let self, self.epoch == epoch, !isSuspended, !Task.isCancelled else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }

    func save(_ routes: FontRouteConfiguration, original: FontLibrarySnapshot, expectedEpoch: UUID) async -> Bool {
        await mutate(expectedEpoch: expectedEpoch) { try await FontConfigurationLibrary.shared.saveRoutes(routes, original: original) }
    }
    func delete(_ asset: FontAssetRecord, original: FontLibrarySnapshot, expectedEpoch: UUID) {
        Task { _ = await mutate(expectedEpoch: expectedEpoch) { try await FontConfigurationLibrary.shared.delete(asset.id, original: original) } }
    }

    func openImportPanel() {
        guard canEdit, let original = catalog?.snapshot else { return }
        let panel = NSOpenPanel(), epoch = epoch
        panel.allowedContentTypes = ["ttf", "otf", "ttc", "woff", "woff2"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.title = NSLocalizedString("上传字体文件", comment: "")
        self.panel = panel; isImportPanelOpen = true
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, self.panel === panel else { return }
            self.panel = nil; isImportPanelOpen = false
            guard response == .OK, self.epoch == epoch, canEdit else { return }
            let urls = panel.urls
            Task { _ = await self.mutate(expectedEpoch: epoch) {
                var snapshot = original
                // 多文件逐个发布；后续失败保留已成功项，并由目录重读呈现实际结果。
                for url in urls { snapshot = try await FontConfigurationLibrary.shared.importFile(url, original: snapshot) }
                return snapshot
            } }
        }
    }
    func cancelImportPanel() {
        let old = panel; panel = nil; isImportPanelOpen = false; old?.cancel(nil)
    }

    private func mutate(expectedEpoch: UUID, operation: @escaping @Sendable () async throws -> FontLibrarySnapshot) async -> Bool {
        guard canEdit, epoch == expectedEpoch else { return false }
        isWorking = true; error = nil
        let previous = loading; previous?.cancel()
        let task = Task { [weak self] () -> Bool in
            await previous?.value
            defer { if let self { isWorking = false; if !isSuspended && catalog == nil { reload() } } }
            do {
                let snapshot = try await operation()
                let catalog = await Task.detached { MacFontCatalog(snapshot) }.value
                guard let self, !isSuspended, epoch == expectedEpoch else { return false }
                self.catalog = catalog; epoch = UUID(); renderRevision = UUID()
                return true
            } catch {
                // 重新读取部分成功的批次；错误仍留在页面，用户可确认实际保留的字体。
                let snapshot = try? await FontConfigurationLibrary.shared.snapshot()
                let catalog = await Task.detached { snapshot.map(MacFontCatalog.init) }.value
                guard let self, !isSuspended, epoch == expectedEpoch else { return false }
                self.catalog = catalog; self.error = error.localizedDescription; renderRevision = UUID()
                return false
            }
        }
        writing = task
        return await task.value
    }
    func suspend() {
        isSuspended = true; epoch = UUID(); isLoading = false
        loading?.cancel(); cancelImportPanel(); catalog = nil; error = nil
    }
    func resume() {
        let reloadNeeded = isSuspended || catalog == nil; isSuspended = false
        if reloadNeeded { reload() }
    }
    func waitForPendingOperations() async { _ = await writing?.value; await loading?.value }
}
