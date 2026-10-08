import Foundation
import Testing
@testable import ETOSCore

@Suite("朗读后台播放器生命周期")
@MainActor
struct TTSPlaybackLifecycleTests {
    @Test("注入设置和空服务不会访问旧设置单例，播放参数取自调用方快照")
    func injectedConfiguration() async {
        var settings = TTSSettingsSnapshot.defaultValue
        settings.playbackSpeed = 1.7
        let manager = TTSManager(urlSession: .shared, settingsProvider: { settings }, serviceProvider: { nil })
        #expect(manager.settings.playbackSpeed == 1.7); #expect(manager.serviceProvider() == nil)
        await manager.stopAndWait(clearHistory: true)
        #expect(manager.playbackState.speed == 1.7)
    }

    @Test("后台准备尚未结束时停止，等待接口不会提前结束或重新开始播放")
    func stopWaitsForPreparation() async {
        let backend = TTSPlaybackStub(suspendsPreparation: true)
        let manager = makeManager(backend)
        let playback = start(manager)
        await backend.waitForPreparation()
        var drained = false
        let stop = Task { await manager.stopAndWait(); drained = true }
        await backend.waitForStop()
        #expect(!drained); #expect(await backend.playCount == 0)
        await backend.releasePreparation()
        await stop.value
        #expect(drained); #expect(await playback.value)
        #expect(await backend.playCount == 0); #expect(manager.playbackState.status == .idle)
    }

    @Test("暂停期间定位和调速不会启动播放，恢复沿用定位结果")
    func pausedSeekingDoesNotResume() async {
        let backend = TTSPlaybackStub()
        let manager = makeManager(backend)
        let playback = start(manager)
        await backend.waitForPlay(count: 1)
        manager.pause(); await manager.audioControlTask?.value
        manager.seekBy(seconds: 12); manager.setPlaybackSpeed(1.5)
        await manager.audioControlTask?.value
        #expect(await backend.playCount == 1); #expect(await backend.time == 12)
        #expect(await backend.speed == 1.5); #expect(manager.playbackState.status == .paused)
        manager.resume(); await backend.waitForPlay(count: 2)
        #expect(await backend.time == 12)
        await manager.stopAndWait()
        #expect(await playback.value)
    }

    @Test("旧分段的延迟结束回调不得结束后续分段")
    func staleCompletionCannotFinishReplacement() async {
        let backend = TTSPlaybackStub()
        let manager = makeManager(backend)
        let first = start(manager)
        await backend.waitForPlay(count: 1)
        let oldCompletion = await backend.completion
        await manager.stopAndWait(); _ = await first.value
        let second = start(manager)
        await backend.waitForPlay(count: 2)
        oldCompletion?(true)
        #expect(manager.audioContinuation != nil); #expect(manager.playbackState.status == .playing)
        await backend.finish()
        #expect(!(await second.value))
        await manager.stopAndWait()
    }

    @Test("清除历史同时释放朗读请求和内存导出，普通停止保留重播请求")
    func explicitHistoryClearing() async {
        let manager = makeManager(TTSPlaybackStub())
        manager.lastReplayRequest = .init(messageID: UUID(), text: "待重播内容", playbackModeOverride: nil,
            serviceOverride: nil, settingsOverride: nil)
        manager.cachedNetworkAudioExport = TTSAudioExport(data: Data([1]), fileExtension: "wav")
        await manager.stopAndWait()
        #expect(manager.canReplayLastRequest); #expect(manager.canExportLastNetworkAudio)
        await manager.stopAndWait(clearHistory: true)
        #expect(!manager.canReplayLastRequest); #expect(!manager.canExportLastNetworkAudio)
    }

    @Test("取消预取后等待其真正返回，不能只清空任务字典就开始恢复数据库")
    func stopDrainsPrefetch() async {
        let manager = makeManager(TTSPlaybackStub()), gate = TTSPrefetchGate()
        let prefetch = Task<TTSManager.AudioClip, Error> {
            await withTaskCancellationHandler { await gate.wait() } onCancel: {
                Task { await gate.cancelled() }
            }
            return .init(data: Data([1]), format: "wav", sampleRate: nil)
        }
        manager.prefetchTasks[UUID()] = prefetch
        await gate.waitUntilStarted()
        var drained = false
        let stop = Task { await manager.stopAndWait(); drained = true }
        await gate.waitUntilCancelled()
        #expect(!drained); #expect(prefetch.isCancelled); #expect(manager.prefetchTasks.isEmpty)
        await gate.release()
        await stop.value
        #expect(drained)
    }

    private func makeManager(_ backend: TTSPlaybackStub) -> TTSManager {
        TTSManager(urlSession: .shared, settingsProvider: { .defaultValue }, serviceProvider: { nil }, makeAudioPlayback: { backend })
    }

    /// 直接使用假后端，测试不访问系统语音、音频设备、网络或真实配置数据库。
    private func start(_ manager: TTSManager) -> Task<Bool, Never> {
        manager.isSpeaking = true
        let playback = Task { () -> Bool in
            do {
                try await manager.playAudio(clip: .init(data: Data([1]), format: "wav", sampleRate: nil), speed: 1)
                return false
            } catch { return error is CancellationError }
        }
        // workerTask 的生产实现直接持有 processQueue；此处把取消也传递到假播放任务。
        manager.workerTask = Task {
            await withTaskCancellationHandler { _ = await playback.value } onCancel: { playback.cancel() }
        }
        return playback
    }
}

private actor TTSPrefetchGate {
    private var started = false
    private var didCancel = false
    private var gate: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { gate = $0 }
    }
    func cancelled() { didCancel = true; cancelWaiter?.resume(); cancelWaiter = nil }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { startWaiter = $0 } } }
    func waitUntilCancelled() async { if !didCancel { await withCheckedContinuation { cancelWaiter = $0 } } }
    func release() { gate?.resume(); gate = nil }
}

private actor TTSPlaybackStub: TTSCloudAudioPlayback {
    let suspendsPreparation: Bool
    var completion: (@MainActor @Sendable (Bool) -> Void)?
    var playCount = 0
    var stopCount = 0
    var time: TimeInterval = 0
    var speed: Float = 1
    private var prepared = false
    private var preparationGate: CheckedContinuation<Void, Never>?
    private var preparationWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var playWaiter: (Int, CheckedContinuation<Void, Never>)?

    init(suspendsPreparation: Bool = false) { self.suspendsPreparation = suspendsPreparation }

    func prepare(clip: TTSManager.AudioClip, speed: Float, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) async throws -> TimeInterval {
        completion = onFinish; self.speed = speed; prepared = true
        preparationWaiter?.resume(); preparationWaiter = nil
        if suspendsPreparation { await withCheckedContinuation { preparationGate = $0 } }
        return 30
    }
    func play() throws {
        try Task.checkCancellation()
        playCount += 1
        if let (count, waiter) = playWaiter, playCount >= count { playWaiter = nil; waiter.resume() }
    }
    func pause() {}
    func seek(to time: TimeInterval) { self.time = time }
    func setSpeed(_ speed: Float) { self.speed = speed }
    func position() -> TTSCloudAudioPosition { .init(time: time, duration: 30) }
    func stop() { stopCount += 1; stopWaiter?.resume(); stopWaiter = nil }
    func finish() async { await completion?(true) }
    func waitForPreparation() async {
        if !prepared { await withCheckedContinuation { preparationWaiter = $0 } }
    }
    func releasePreparation() { preparationGate?.resume(); preparationGate = nil }
    func waitForStop() async {
        if stopCount == 0 { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func waitForPlay(count: Int) async {
        if playCount < count { await withCheckedContinuation { playWaiter = (count, $0) } }
    }
}
