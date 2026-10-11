import AppKit
import Combine
import ETOSCore
@preconcurrency import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MacBackgroundModel: ObservableObject {
    @Published private(set) var catalog = MacBackgroundCatalog([])
    @Published private(set) var selectedFile: MacBackgroundFile?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = true
    @Published private(set) var isImportPanelOpen = false
    @Published private(set) var isPhotoPickerOpen = false
    @Published private(set) var cropDraft: MacBackgroundCropDraft?
    @Published private(set) var epoch = UUID()
    @Published var error: String?
    let playback = MacBackgroundPlayback()
    private let library: MacBackgroundLibrary
    private var loading: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private var preparingCrop: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var panel: NSOpenPanel?
    private var started = false
    private var rotatedAtLaunch = false
    private var visible = false
    private var appActive = false
    private var loaded = false

    init(library: MacBackgroundLibrary = .shared) { self.library = library }
    var isPresentingMedia: Bool { isImportPanelOpen || isPhotoPickerOpen || cropDraft != nil }
    var canEdit: Bool { loaded && !isLoading && !isWorking && !isSuspended && !isPresentingMedia && AppLockManager.shared.state != .locked }

    func start() {
        guard !started else { return }
        started = true; appActive = NSApplication.shared.isActive
        let configuration = AppConfigStore.shared
        configuration.$currentBackgroundImage.combineLatest(configuration.$enableBackground,
            configuration.$continueVideoBackgroundPlaybackWhenChatHidden)
            .dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateSelection() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .syncBackgroundsUpdated).receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, (notification.object as? MacBackgroundModel) !== self else { return }
                reload()
            }.store(in: &subscriptions)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.appActive = NSApplication.shared.isActive
                self?.updatePlayback()
            }.store(in: &subscriptions)
        }
    }

    func reload(preserveError: Bool = false) {
        guard !isSuspended, !isWorking, !isImportPanelOpen, AppLockManager.shared.state != .locked else { return }
        isPhotoPickerOpen = false; cancelCrop()
        let previous = loading; previous?.cancel()
        epoch = UUID(); let epoch = epoch, library = library
        isLoading = true
        if !preserveError { error = nil }
        loading = Task { [weak self] in
            await previous?.value
            do {
                let catalog = try await library.load()
                guard let self, self.epoch == epoch, !isSuspended, !Task.isCancelled else { return }
                self.catalog = catalog; loaded = true; isLoading = false
                let configuration = AppConfigStore.shared
                let current = configuration.currentBackgroundImage
                if !rotatedAtLaunch {
                    rotatedAtLaunch = true
                    if configuration.enableAutoRotateBackground,
                       let next = catalog.nextRotatedID(excluding: current) {
                        configuration.currentBackgroundImage = next
                    }
                }
                if catalog.byID[configuration.currentBackgroundImage] == nil {
                    configuration.currentBackgroundImage = catalog.identifiers.first ?? ""
                }
                updateSelection()
            } catch {
                guard let self, self.epoch == epoch, !isSuspended, !Task.isCancelled else { return }
                isLoading = false; self.error = error.localizedDescription
            }
        }
    }

    func select(_ id: String, expectedEpoch: UUID) {
        guard canEdit, epoch == expectedEpoch, catalog.byID[id] != nil else { return }
        guard AppConfigStore.shared.currentBackgroundImage != id else { return }
        AppConfigStore.shared.currentBackgroundImage = id
        updateSelection()
    }

    func openImportPanel() {
        guard canEdit else { return }
        let panel = NSOpenPanel(), epoch = epoch
        panel.allowedContentTypes = [.png, .jpeg, .webP, .mpeg4Movie, .quickTimeMovie]
        if let m4v = UTType(filenameExtension: "m4v") { panel.allowedContentTypes.append(m4v) }
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = NSLocalizedString("导入背景", comment: "")
        self.panel = panel; isImportPanelOpen = true
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, self.panel === panel else { return }
            self.panel = nil; isImportPanelOpen = false
            guard response == .OK, let url = panel.url, self.epoch == epoch, canEdit else { reload(); return }
            importFile(url, expectedEpoch: epoch)
        }
    }

    func cancelImportPanel() {
        guard let oldPanel = panel else { return }
        panel = nil; isImportPanelOpen = false; oldPanel.cancel(nil)
        if !isSuspended { reload() }
    }

    func importFile(_ url: URL, expectedEpoch: UUID) {
        guard canEdit, epoch == expectedEpoch else { return }
        mutate(expectedEpoch: expectedEpoch) { [library] in try await library.importFile(url).id }
    }

    func setPhotoPickerPresented(_ presented: Bool) {
        guard !presented || canEdit else { return }
        isPhotoPickerOpen = presented
    }

    func importPhoto(_ item: PhotosPickerItem, expectedEpoch: UUID) {
        guard epoch == expectedEpoch else { return }
        isPhotoPickerOpen = false
        guard canEdit else { return }
        mutate(expectedEpoch: expectedEpoch) { [library] in try await library.importPhoto(item).id }
    }

    func beginCrop(_ file: MacBackgroundFile, expectedEpoch: UUID) {
        guard canEdit, epoch == expectedEpoch, !file.isVideo, catalog.byID[file.id] == file else { return }
        let draft = MacBackgroundCropDraft(file: file, sourceEpoch: epoch), library = library
        cropDraft = draft
        let previous = preparingCrop
        previous?.cancel()
        preparingCrop = Task { [weak self, weak draft] in
            await previous?.value
            do {
                let prepared = try await library.prepareCrop(file)
                guard let self, let draft, cropDraft?.id == draft.id, epoch == expectedEpoch, !isSuspended, !Task.isCancelled else { return }
                draft.prepared = prepared; draft.isPreparing = false
            } catch {
                guard let self, let draft, cropDraft?.id == draft.id, epoch == expectedEpoch, !isSuspended, !Task.isCancelled else { return }
                draft.error = error.localizedDescription; draft.isPreparing = false
            }
        }
    }

    func canSaveCrop(_ draft: MacBackgroundCropDraft) -> Bool {
        !isSuspended && !isLoading && !isWorking && cropDraft?.id == draft.id && epoch == draft.sourceEpoch
            && draft.prepared != nil && !draft.isPreparing && AppLockManager.shared.state != .locked
    }

    func saveCrop(_ draft: MacBackgroundCropDraft) {
        guard canSaveCrop(draft) else { return }
        draft.error = nil
        let file = draft.file, parameters = draft.parameters
        mutate(expectedEpoch: draft.sourceEpoch, cropID: draft.id) { [library] in
            try await library.saveCrop(file, parameters: parameters).id
        }
    }

    func cancelCrop(id: UUID? = nil) {
        guard id == nil || cropDraft?.id == id else { return }
        preparingCrop?.cancel(); cropDraft = nil
    }

    func delete(_ file: MacBackgroundFile, expectedEpoch: UUID) {
        guard canEdit, epoch == expectedEpoch, catalog.byID[file.id] == file else { return }
        mutate(expectedEpoch: expectedEpoch, deletedID: file.id) { [library] in try await library.delete(file); return nil }
    }

    private func mutate(expectedEpoch: UUID, deletedID: String? = nil, cropID: UUID? = nil,
                        operation: @escaping @Sendable () async throws -> String?) {
        isWorking = true; error = nil
        let previous = loading
        previous?.cancel()
        writing = Task { [weak self] in
            await previous?.value
            defer {
                if let self { isWorking = false; if !isSuspended && cropDraft == nil { reload(preserveError: true) } }
            }
            do {
                try Task.checkCancellation()
                let importedID = try await operation()
                // 已接受的删除即使遇到锁定也完成配置收尾；备份屏障等待本任务，避免保存悬空选择。
                if let deletedID, AppConfigStore.shared.currentBackgroundImage == deletedID {
                    AppConfigStore.shared.currentBackgroundImage = ""
                }
                NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: self)
                guard let self, epoch == expectedEpoch, !isSuspended, !Task.isCancelled else { return }
                if let importedID { AppConfigStore.shared.currentBackgroundImage = importedID }
                if cropDraft?.id == cropID { cropDraft = nil }
            } catch {
                guard let self, epoch == expectedEpoch, !isSuspended, !Task.isCancelled else { return }
                if let cropID, cropDraft?.id == cropID { cropDraft?.error = error.localizedDescription }
                else { self.error = error.localizedDescription }
            }
        }
    }

    func setVisible(_ visible: Bool) { self.visible = visible; updatePlayback() }

    private func updateSelection() {
        guard !isSuspended else { return }
        let configuration = AppConfigStore.shared
        selectedFile = catalog.byID[configuration.currentBackgroundImage]
        playback.load(configuration.enableBackground && selectedFile?.isVideo == true ? selectedFile : nil)
        updatePlayback()
    }

    private func updatePlayback() {
        let configuration = AppConfigStore.shared
        playback.update(shouldPlay: !isSuspended && MacBackgroundPlaybackPolicy.shouldPlay(
            enabled: configuration.enableBackground, visible: visible, appActive: appActive,
            continueWhenHidden: configuration.continueVideoBackgroundPlaybackWhenChatHidden))
    }

    func suspend() {
        isSuspended = true; epoch = UUID(); loaded = false; isLoading = false
        loading?.cancel(); writing?.cancel(); playback.suspend()
        isPhotoPickerOpen = false; cancelCrop()
        cancelImportPanel()
        catalog = MacBackgroundCatalog([]); selectedFile = nil; error = nil
    }

    func resume() {
        let wasSuspended = isSuspended
        isSuspended = false
        if !isWorking && (wasSuspended || !loaded) { reload() }
    }

    func waitForPendingOperations() async {
        await writing?.value; await preparingCrop?.value; await loading?.value; await playback.waitForPendingOperations()
    }
}
