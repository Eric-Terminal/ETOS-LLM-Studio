import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacSpeechInputTests {
    @Test("语音模型目录保留专用选择与自动回退，但向导不包含凭据")
    func modelCatalog() {
        let provider = Provider(name: "转写服务", baseURL: "https://private.example", apiKeys: ["private-key"], apiFormat: "openai-compatible")
        let remote = RunnableModel(provider: provider, model: Model(modelName: "whisper", isActivated: false))
        let system = ChatService.systemSpeechRecognizerRunnableModel
        let catalog = MacSpeechModelCatalog.prepare([system, remote])
        #expect(catalog.resolve("") == system)
        #expect(catalog.resolve("removed") == system)
        #expect(catalog.resolve(remote.id) == remote)
        #expect(catalog.identifiers == ["", system.id, remote.id])
        let encoded = GuideToolArguments.encodedResult(catalog.guideValue)
        #expect(!encoded.contains("private-key")); #expect(!encoded.contains("private.example"))
    }

    @Test("录音启动期间取消仍等待设备清理，迟到启动不恢复旧草稿")
    @MainActor
    func cancelledStartIsDrained() async {
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let recorder = FakeMacSpeechRecorder(started: continuation, blocksStart: true)
        let model = MacSpeechInputModel(recorder: recorder, requestPermission: { $0(true) }, isInputAllowed: { true })
        model.resume()
        let source = MacSpeechInputSource(sessionID: UUID(), composerContextID: UUID(), format: .wav, model: nil)
        model.begin(source)
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        model.suspend()
        await recorder.releaseStart()
        await model.waitForPendingOperations()
        #expect(model.phase == .idle); #expect(model.source == nil); #expect(model.attachment == nil)
        #expect(await recorder.discardedAfterStart)
        #expect(model.result(sourceID: source.id) == nil)
        continuation.finish()
    }

    @Test("预览只交付给当前录音来源，错误来源不能停止或领取音频")
    @MainActor
    func previewSourceIdentity() async {
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let recorder = FakeMacSpeechRecorder(started: continuation, blocksStart: false)
        let model = MacSpeechInputModel(recorder: recorder, requestPermission: { $0(true) }, isInputAllowed: { true })
        model.resume()
        let source = MacSpeechInputSource(sessionID: UUID(), composerContextID: UUID(), format: .aac, model: nil)
        model.begin(source)
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        await model.waitForPendingOperations()
        model.stopRecording(sourceID: UUID())
        #expect(model.phase == .recording)
        model.stopRecording(sourceID: source.id)
        await model.waitForPendingOperations()
        #expect(model.phase == .preview)
        #expect(model.result(sourceID: UUID()) == nil)
        if case .audio(let audio)? = model.result(sourceID: source.id) {
            #expect(audio.data == Data([1, 2, 3]))
            #expect(audio.format == "m4a")
        } else { Issue.record("预览应返回已录制的音频") }
        model.close(sourceID: UUID())
        #expect(model.phase == .preview)
        model.close(sourceID: source.id)
        await model.waitForPendingOperations()
        #expect(model.attachment == nil)
        continuation.finish()
    }
}

private actor FakeMacSpeechRecorder: MacSpeechRecording {
    let started: AsyncStream<Void>.Continuation
    let blocksStart: Bool
    private var pendingStart: CheckedContinuation<Void, Never>?
    private var didStart = false
    private(set) var discardedAfterStart = false
    init(started: AsyncStream<Void>.Continuation, blocksStart: Bool) { self.started = started; self.blocksStart = blocksStart }
    func start(format: AudioRecordingFormat, stopped: @escaping @MainActor @Sendable () -> Void) async throws {
        didStart = true
        if blocksStart {
            await withCheckedContinuation { continuation in pendingStart = continuation; started.yield(()) }
        } else { started.yield(()) }
    }
    func releaseStart() { pendingStart?.resume(); pendingStart = nil }
    func finish() -> AudioAttachment { AudioAttachment(data: Data([1, 2, 3]), mimeType: "audio/m4a", format: "m4a", fileName: "recording.m4a") }
    func discard() { if didStart { discardedAfterStart = true } }
}
