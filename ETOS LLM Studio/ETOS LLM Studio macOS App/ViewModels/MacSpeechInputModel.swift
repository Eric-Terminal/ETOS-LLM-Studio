import AVFoundation
import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSpeechInputModel: ObservableObject {
    enum Phase: String { case idle, preparing, recording, processing, preview, transcribing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var source: MacSpeechInputSource?
    @Published private(set) var attachment: AudioAttachment?
    @Published private(set) var recordedAt: Date?
    @Published var transcript = ""
    @Published var error: String?
    @Published private(set) var catalog = MacSpeechModelCatalog.empty
    @Published private(set) var catalogID = UUID()
    @Published private(set) var isSuspended = true
    private var service: ChatService?
    private var subscriptions = Set<AnyCancellable>()
    private let recorder: any MacSpeechRecording
    private let requestPermission: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    private let isInputAllowed: @MainActor () -> Bool
    private var operation: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var loadID = UUID()
    private var generation = UUID()
    var isActive: Bool { source != nil }

    init(recorder: any MacSpeechRecording = MacSpeechRecorder(),
         requestPermission: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) },
         isInputAllowed: @escaping @MainActor () -> Bool = { AppConfigStore.shared.enableSpeechInput && AppLockManager.shared.state != .locked }) {
        self.recorder = recorder; self.requestPermission = requestPermission; self.isInputAllowed = isInputAllowed
    }

    func start(service: ChatService) {
        subscriptions.removeAll()
        self.service = service
        service.providersSubject.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reloadModels() }.store(in: &subscriptions)
    }

    func reloadModels() {
        guard !isSuspended, let service else { return }
        let previous = loading
        previous?.cancel(); loadID = UUID()
        let id = loadID
        loading = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { MacSpeechModelCatalog.prepare(service.activatedSpeechModels) }
            let catalog = await worker.value
            guard let self, !Task.isCancelled, loadID == id, !isSuspended else { return }
            self.catalog = catalog; catalogID = UUID()
        }
    }

    func begin(_ source: MacSpeechInputSource) {
        guard !isSuspended, isInputAllowed() else { return }
        cancel()
        self.source = source; phase = .preparing
        let generation = generation
        // 系统权限弹窗无法被 App 关闭；不把用户作答作为退出/恢复的等待条件。
        // 回调只持有弱引用和代次，取消后即使获得权限也不能开始录音。
        requestPermission { [weak self] allowed in
            Task { @MainActor [weak self] in
                guard let self, accepts(generation), phase == .preparing else { return }
                guard allowed else {
                    phase = .idle; error = NSLocalizedString("麦克风权限被拒绝，请到设置中开启。", comment: "")
                    return
                }
                startRecorder(generation: generation, format: source.format)
            }
        }
    }

    private func startRecorder(generation: UUID, format: AudioRecordingFormat) {
        let previous = operation, recorder = recorder
        operation = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await recorder.start(format: format) { [weak self] in
                    guard let self, accepts(generation), phase == .recording else { return }
                    stopRecording()
                }
                guard let self, accepts(generation) else { return }
                recordedAt = Date(); phase = .recording
            } catch {
                guard let self, accepts(generation) else { return }
                self.error = error.localizedDescription; phase = .idle
            }
        }
    }

    func stopRecording(sourceID: UUID) { if source?.id == sourceID { stopRecording() } }

    private func stopRecording() {
        guard phase == .recording, !isSuspended else { return }
        phase = .processing
        let generation = generation, recorder = recorder, previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let attachment = try await recorder.finish()
                guard let self, accepts(generation) else { return }
                self.attachment = attachment; phase = .preview
            } catch {
                guard let self, accepts(generation) else { return }
                self.error = error.localizedDescription; phase = .idle
            }
        }
    }

    func transcribe(sourceID: UUID) {
        guard source?.id == sourceID, phase == .preview, let attachment, let model = source?.model, let service, !isSuspended else { return }
        phase = .transcribing; error = nil
        let generation = generation, previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                // RunnableModel 相等只比较 ID，必须比较内部配置才能发现凭据和端点变化。
                guard let current = service.activatedSpeechModels.first(where: { $0.id == model.id }),
                      current.provider == model.provider, current.model == model.model else {
                    throw MCPConfigurationWriteError.changedExternally
                }
                let text = try await service.transcribeAudio(using: model, audioData: attachment.data,
                    fileName: attachment.fileName, mimeType: attachment.mimeType)
                try Task.checkCancellation()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw SystemSpeechRecognizerService.TranscriptionError.emptyResult }
                return trimmed
            }
            do {
                let text = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, accepts(generation) else { return }
                transcript = text; phase = .preview
            } catch {
                guard let self, accepts(generation) else { return }
                self.error = error.localizedDescription; phase = .preview
            }
        }
    }

    func result(sourceID: UUID) -> MacSpeechInputResult? {
        guard source?.id == sourceID, phase == .preview, !isSuspended else { return nil }
        if source?.sendsAudio == true { return attachment.map(MacSpeechInputResult.audio) }
        return transcript.isEmpty ? nil : .text(transcript)
    }

    func close(sourceID: UUID) { if source?.id == sourceID { cancel() } }

    func cancel() {
        generation = UUID(); source = nil; phase = .idle; recordedAt = nil
        attachment = nil; transcript = ""; error = nil
        let previous = operation, recorder = recorder
        previous?.cancel()
        operation = Task { await previous?.value; await recorder.discard() }
    }

    func suspend() {
        isSuspended = true; loadID = UUID(); loading?.cancel()
        catalog = .empty; catalogID = UUID(); cancel()
    }
    func resume() { isSuspended = false; reloadModels() }
    func waitForPendingOperations() async { await operation?.value; await loading?.value }

    private func accepts(_ generation: UUID) -> Bool {
        !Task.isCancelled && self.generation == generation && !isSuspended && isInputAllowed()
    }
}
