import Foundation
import Testing
@testable import ETOSCore

@Suite("发送前音频试听")
@MainActor
struct AudioAttachmentPreviewPlayerTests {
    private func attachment(fileName: String = "录音.wav") -> AudioAttachment {
        AudioAttachment(data: Data([1, 2, 3]), mimeType: "audio/wav", format: "wav", fileName: fileName)
    }

    @Test("准备草稿不会自动播放，暂停后定位与续播保留位置")
    func previewDoesNotAutoplayAndResumes() async {
        let backend = PreviewPlaybackStub()
        let player = AudioAttachmentPreviewPlayer(makePlayback: { backend })
        defer { player.stop() }

        await player.prepare(attachment())
        #expect(player.state == .ready)
        #expect(player.duration == 30)
        #expect(await backend.playCount == 0)

        await player.seek(toProgress: 0.5)
        #expect(player.currentTime == 15)
        #expect(await backend.playCount == 0)
        await player.togglePlayback()
        #expect(player.state == .playing)
        await player.togglePlayback()
        #expect(player.state == .paused)
        #expect(player.currentTime == 15)

        await player.seek(toProgress: 0.75)
        #expect(player.state == .paused)
        #expect(await backend.playCount == 1)
        await player.togglePlayback()
        #expect(player.state == .playing)
        #expect(await backend.time == 22.5)
    }

    @Test("播放结束保留总时长，重播从头开始")
    func completionAndReplay() async {
        let backend = PreviewPlaybackStub()
        let player = AudioAttachmentPreviewPlayer(makePlayback: { backend })
        defer { player.stop() }
        await player.prepare(attachment())
        await player.togglePlayback()
        await backend.finish(successfully: true)
        #expect(player.state == .ready)
        #expect(player.progress == 1)
        await player.togglePlayback()
        #expect(player.state == .playing)
        #expect(await backend.time == 0)
    }

    @Test("退出试听后迟到的准备结果不能恢复播放状态")
    func stoppingDuringPreparationDiscardsResult() async {
        let backend = PreviewPlaybackStub(suspendsPreparation: true)
        let player = AudioAttachmentPreviewPlayer(makePlayback: { backend })
        let preparation = Task { await player.prepare(attachment()) }
        await backend.waitForPreparation()
        #expect(player.state == .preparing)
        player.stop()
        await backend.completePreparation()
        await preparation.value
        #expect(player.state == .idle)
        #expect(player.duration == 0)
        #expect(await backend.playCount == 0)
        #expect(await backend.stopCount > 0)
    }

    @Test("取消准备后释放播放器并清除加载状态")
    func cancellingPreparationResetsState() async {
        let backend = PreviewPlaybackStub(suspendsPreparation: true)
        let player = AudioAttachmentPreviewPlayer(makePlayback: { backend })
        let preparation = Task { await player.prepare(attachment()) }
        await backend.waitForPreparation()
        preparation.cancel()
        await backend.completePreparation()
        await preparation.value
        #expect(player.state == .idle)
        #expect(await backend.stopCount > 0)
    }

    @Test("同名的新附件有独立身份，旧播放回调不能覆盖新草稿")
    func replacementIgnoresOldCompletion() async {
        let original = attachment()
        let replacement = attachment()
        #expect(original.id != replacement.id)
        let copied = original
        #expect(copied.id == original.id)

        let backend = PreviewPlaybackStub()
        let player = AudioAttachmentPreviewPlayer(makePlayback: { backend })
        defer { player.stop() }
        await player.prepare(original)
        let oldCompletion = await backend.completion
        await player.prepare(replacement)
        oldCompletion?(true)
        #expect(player.state == .ready)
        #expect(player.currentTime == 0)
        #expect(player.progress == 0)
    }

    @Test("准备失败与系统拒绝播放时明确进入错误状态")
    func preparationAndPlaybackFailures() async {
        let failedPreparation = PreviewPlaybackStub(failsPreparation: true)
        let first = AudioAttachmentPreviewPlayer(makePlayback: { failedPreparation })
        defer { first.stop() }
        await first.prepare(attachment())
        #expect(first.state == .failed)
        #expect(!first.canPlay)

        let failedPlayback = PreviewPlaybackStub(failsPlayback: true)
        let second = AudioAttachmentPreviewPlayer(makePlayback: { failedPlayback })
        defer { second.stop() }
        await second.prepare(attachment())
        await second.togglePlayback()
        #expect(second.state == .failed)
        #expect(!second.isUpdatingPlayback)
        #expect(!second.canPlay)
    }

    @Test("发送或移除草稿时停止试听，旧的结束回调不能恢复进度")
    func stopInvalidatesPlaybackCompletion() async {
        let backend = PreviewPlaybackStub()
        let player = AudioAttachmentPreviewPlayer(makePlayback: { backend })
        await player.prepare(attachment())
        await player.togglePlayback()
        let completion = await backend.completion
        player.stop()
        completion?(true)
        #expect(player.state == .idle)
        #expect(player.currentTime == 0)
        #expect(player.duration == 0)
        #expect(!player.canPlay)
    }

    @Test("发送前试听可检索到语音输入教程")
    func previewKnowledgeIsDiscoverable() async {
        let service = GuideKnowledgeService()
        let references = await service.search("发送前试听", limit: 1)
        #expect(references.first?.id == "speech-input")
    }
}

private actor PreviewPlaybackStub: AudioAttachmentPreviewPlayback {
    let suspendsPreparation: Bool
    let failsPreparation: Bool
    let failsPlayback: Bool
    private(set) var time: TimeInterval = 0
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var completion: (@MainActor @Sendable (Bool) -> Void)?
    private var isPlaying = false
    private var preparationStarted = false
    private var preparationWaiter: CheckedContinuation<Void, Never>?
    private var preparationContinuation: CheckedContinuation<Void, Never>?

    init(suspendsPreparation: Bool = false, failsPreparation: Bool = false, failsPlayback: Bool = false) {
        self.suspendsPreparation = suspendsPreparation
        self.failsPreparation = failsPreparation
        self.failsPlayback = failsPlayback
    }

    func prepare(data: Data, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) async throws -> TimeInterval {
        completion = onFinish
        preparationStarted = true
        preparationWaiter?.resume()
        preparationWaiter = nil
        if suspendsPreparation {
            await withCheckedContinuation { preparationContinuation = $0 }
        }
        if failsPreparation { throw StubError.failed }
        return 30
    }

    func waitForPreparation() async {
        if preparationStarted { return }
        await withCheckedContinuation { preparationWaiter = $0 }
    }

    func completePreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func play() throws {
        if failsPlayback { throw StubError.failed }
        playCount += 1
        isPlaying = true
    }

    func pause() -> TimeInterval {
        isPlaying = false
        return time
    }

    func seek(to time: TimeInterval) { self.time = time }

    func position() -> AudioAttachmentPreviewPosition {
        AudioAttachmentPreviewPosition(time: time, isPlaying: isPlaying)
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }

    func finish(successfully: Bool) async {
        isPlaying = false
        await completion?(successfully)
    }

    private enum StubError: Error { case failed }
}
