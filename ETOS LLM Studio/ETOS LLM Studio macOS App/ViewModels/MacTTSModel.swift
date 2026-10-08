import AppKit
import Combine
import ETOSCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MacTTSModel: ObservableObject {
    @Published var draft = TTSSettingsSnapshot.defaultValue
    @Published private(set) var presentation: MacTTSPresentation?
    @Published private(set) var voices: [MacTTSVoiceRow] = []
    @Published private(set) var epoch = UUID()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSuspended = true
    @Published private(set) var isStopping = false
    @Published private(set) var isExporting = false
    @Published private(set) var isExportPanelOpen = false
    @Published var error: String?
    private var loading: Task<Void, Never>?
    private var writing: Task<Bool, Never>?
    private var stopping: Task<Void, Never>?
    private var exporting: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var readID = UUID()
    private var sessionContext = UUID()
    private var sessionID: UUID?
    private var subscriptions = Set<AnyCancellable>()
    private let tracker = MacTTSAutoPlayTracker()
    private var exportPanel: NSSavePanel?
    private var previewOwner: UUID?
    private var isStarted = false
    private var stopID = UUID()
    private let loadSnapshot: @Sendable () async throws -> TTSConfigurationSnapshot
    private let saveSnapshot: @Sendable (TTSConfigurationSnapshot, TTSConfigurationSnapshot) async throws -> TTSConfigurationSnapshot
    private let loadVoices: @Sendable () -> [MacTTSVoiceRow]

    init(loadSnapshot: @escaping @Sendable () async throws -> TTSConfigurationSnapshot = { try await TTSConfigurationLibrary.shared.snapshot() },
         saveSnapshot: @escaping @Sendable (TTSConfigurationSnapshot, TTSConfigurationSnapshot) async throws -> TTSConfigurationSnapshot = { try await TTSConfigurationLibrary.shared.save($0, replacing: $1) },
         loadVoices: @escaping @Sendable () -> [MacTTSVoiceRow] = { MacTTSPresentation.voices() }) {
        self.loadSnapshot = loadSnapshot; self.saveSnapshot = saveSnapshot; self.loadVoices = loadVoices
    }

    lazy var player = TTSManager(settingsProvider: { [weak self] in
        self?.presentation?.snapshot.settings ?? .defaultValue
    }, serviceProvider: { [weak self] in self?.presentation?.selected })

    var isLoaded: Bool { presentation != nil }
    var canEdit: Bool { isLoaded && !isLoading && !isSaving && !isSuspended && !isStopping && AppLockManager.shared.state != .locked }
    var canPlay: Bool { canEdit && !isExporting && !isExportPanelOpen }

    func start(service: ChatService) {
        guard !isStarted else { return }
        isStarted = true
        service.sessionRequestStatusSubject.receive(on: DispatchQueue.main).sink { [weak self, weak service] event in
            guard let self, !isSuspended, !isStopping, service?.currentSessionSubject.value?.id == event.sessionID else { return }
            receive(event)
        }.store(in: &subscriptions)
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.player.setApplicationIsInBackground(!NSApplication.shared.isActive)
            }.store(in: &subscriptions)
        }
        AppConfigStore.shared.$continueTTSPlaybackInBackground.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.player.setApplicationIsInBackground(!NSApplication.shared.isActive)
        }.store(in: &subscriptions)
        AppConfigStore.shared.$appLanguage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshLabels()
        }.store(in: &subscriptions)
        player.setApplicationIsInBackground(!NSApplication.shared.isActive)
    }

    func reload() {
        guard !isSuspended, !isSaving, !isStopping, AppLockManager.shared.state != .locked else { return }
        let previous = loading
        previous?.cancel(); epoch = UUID()
        let epoch = epoch, loadSnapshot = loadSnapshot, loadVoices = loadVoices
        isLoading = true; error = nil
        loading = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    let snapshot = try await loadSnapshot()
                    return (MacTTSPresentation.prepare(snapshot), loadVoices())
                }
                let (prepared, voices) = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
                guard let self, !Task.isCancelled, self.epoch == epoch, !isSuspended else { return }
                presentation = prepared; draft = prepared.snapshot.settings; self.voices = voices; isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.epoch == epoch else { return }
                self.error = error.localizedDescription; isLoading = false
            }
        }
    }

    private func refreshLabels() {
        guard let snapshot = presentation?.snapshot, !isSuspended, !isLoading, !isSaving else { return }
        let epoch = epoch, previous = loading
        loading = Task { [weak self] in
            await previous?.value
            let prepared = await Task.detached { MacTTSPresentation.prepare(snapshot) }.value
            guard let self, !Task.isCancelled, self.epoch == epoch, !isSuspended else { return }
            presentation = prepared
        }
    }

    func saveSettings() {
        guard var candidate = presentation?.snapshot else { return }
        candidate.settings = draft
        _ = write(candidate, expectedEpoch: epoch, replaceDraft: true)
    }

    func selectService(_ id: UUID?) {
        guard var candidate = presentation?.snapshot else { return }
        candidate.selectedServiceID = id
        _ = write(candidate, expectedEpoch: epoch)
    }

    func saveService(_ service: TTSServiceConfiguration, expectedEpoch: UUID) async -> Bool {
        guard var candidate = presentation?.snapshot else { return false }
        if let index = candidate.services.firstIndex(where: { $0.id == service.id }) { candidate.services[index] = service }
        else { candidate.services.append(service); candidate.selectedServiceID = service.id }
        guard let task = write(candidate, expectedEpoch: expectedEpoch) else { return false }
        return await task.value
    }

    func deleteService(_ id: UUID, expectedEpoch: UUID) {
        guard var candidate = presentation?.snapshot else { return }
        candidate.services.removeAll { $0.id == id }
        _ = write(candidate, expectedEpoch: expectedEpoch)
    }

    func moveService(_ id: UUID, offset: Int) {
        guard var candidate = presentation?.snapshot,
              let index = candidate.services.firstIndex(where: { $0.id == id }), candidate.services.indices.contains(index + offset) else { return }
        candidate.services.swapAt(index, index + offset)
        _ = write(candidate, expectedEpoch: epoch)
    }

    private func write(_ candidate: TTSConfigurationSnapshot, expectedEpoch: UUID, replaceDraft: Bool = false) -> Task<Bool, Never>? {
        guard canEdit, epoch == expectedEpoch, let original = presentation?.snapshot else { return nil }
        isSaving = true; error = nil
        let pendingRead = loading
        let saveSnapshot = saveSnapshot
        pendingRead?.cancel()
        let task = Task { [weak self] () -> Bool in
            await pendingRead?.value
            defer {
                if let self {
                    isSaving = false
                    if !isSuspended && !isLoaded && !isStopping { reload() }
                }
            }
            do {
                let prepared = try await Task.detached {
                    MacTTSPresentation.prepare(try await saveSnapshot(candidate, original))
                }.value
                guard let self, epoch == expectedEpoch, !isSuspended else { return false }
                presentation = prepared
                if replaceDraft { draft = prepared.snapshot.settings }
                epoch = UUID()
                return true
            } catch {
                guard let self, epoch == expectedEpoch, !isSuspended else { return false }
                self.error = error.localizedDescription
                return false
            }
        }
        writing = task
        return task
    }

    func showSession(_ id: UUID?) {
        guard sessionID != id else { return }
        sessionID = id; sessionContext = UUID()
        events?.cancel()
        stop(); drainPlayback()
    }

    func read(_ message: ChatMessage, sessionID: UUID) {
        guard canPlay, self.sessionID == sessionID, MessageActionBarAvailability.canReadAloud(message) else { return }
        if player.isSpeaking && player.currentSpeakingMessageID == message.id { stop(); return }
        prepareRead(message.content, messageID: message.id)
    }

    func preview(settings: TTSSettingsSnapshot, service: TTSServiceConfiguration?, owner: UUID) {
        guard canPlay else { return }
        previewOwner = owner
        prepareRead(NSLocalizedString("你好，这是一段语音试听。", comment: ""), messageID: nil,
            settings: settings, service: service, owner: owner)
    }

    private func prepareRead(_ text: String, messageID: UUID?, settings: TTSSettingsSnapshot? = nil,
                             service: TTSServiceConfiguration? = nil, owner: UUID? = nil) {
        readID = UUID(); reading?.cancel()
        let id = readID, context = sessionContext, previous = reading
        reading = Task { [weak self] in
            await previous?.value
            let hasText = await Task.detached { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.value
            guard let self, !Task.isCancelled, id == readID, context == sessionContext, canPlay, hasText else { return }
            previewOwner = owner
            player.speak(text, messageID: messageID, playbackModeOverride: service == nil ? nil : .cloud,
                serviceOverride: service, settingsOverride: settings)
        }
    }

    private func receive(_ event: ChatService.SessionRequestStatusEvent) {
        let previous = events, context = sessionContext, sessionID = sessionID, tracker = tracker
        events = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let message = await tracker.process(event, context: context, sessionID: sessionID)
            guard let self, !Task.isCancelled, sessionContext == context, canPlay,
                  presentation?.snapshot.settings.autoPlayAfterAssistantResponse == true, let message else { return }
            guard !(player.currentSpeakingMessageID == message.id && player.isSpeaking) else { return }
            prepareRead(message.content, messageID: message.id)
        }
    }

    func stopPreview(owner: UUID) { if previewOwner == owner { stop() } }
    func stop() { readID = UUID(); reading?.cancel(); previewOwner = nil; player.stop() }

    func suspend() {
        isSuspended = true; epoch = UUID(); sessionContext = UUID()
        loading?.cancel(); events?.cancel(); stop()
        exportPanel?.cancel(nil); exportPanel = nil; isExportPanelOpen = false
        isLoading = false; presentation = nil; draft = .defaultValue; voices = []; error = nil
        drainPlayback()
    }

    private func drainPlayback() {
        isStopping = true
        stopID = UUID()
        let previous = stopping, player = player, id = stopID, pendingEvents = events, tracker = tracker
        stopping = Task { [weak self] in
            await previous?.value
            await player.stopAndWait(clearHistory: true)
            await pendingEvents?.value
            await tracker.reset()
            guard let self, stopID == id else { return }
            isStopping = false
            if !isSuspended && !isSaving && !isLoaded { reload() }
        }
    }

    func resume() { isSuspended = false; if !isLoaded && !isLoading && !isSaving && !isStopping { reload() } }
    func waitForPendingOperations() async {
        _ = await writing?.value; await loading?.value; await reading?.value
        await events?.value; await stopping?.value; await exporting?.value
    }

    func exportAudio() {
        guard canPlay, let audio = player.lastNetworkAudioExport() else { return }
        let panel = NSSavePanel(), epoch = epoch
        panel.allowedContentTypes = [UTType(filenameExtension: audio.fileExtension) ?? .audio]
        panel.nameFieldStringValue = "\(NSLocalizedString("语音输出", comment: "")).\(audio.fileExtension)"
        exportPanel = panel; isExportPanelOpen = true
        panel.begin { [weak self, weak panel] result in
            guard let self, let panel, exportPanel === panel else { return }
            isExportPanelOpen = false; exportPanel = nil
            guard result == .OK, let url = panel.url, self.epoch == epoch, canPlay else { return }
            isExporting = true
            exporting = Task { [weak self] in
                defer { self?.isExporting = false }
                do {
                    try await Task.detached {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        try audio.data.write(to: url, options: .atomic)
                    }.value
                } catch {
                    guard let self, self.epoch == epoch, !isSuspended else { return }
                    self.error = NSLocalizedString("导出失败", comment: "")
                }
            }
        }
    }
}
