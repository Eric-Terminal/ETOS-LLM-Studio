import Testing
@testable import ETOSCore

@Suite("朗读浮窗显示与自动收起")
struct TTSFloatingPanelPresentationTests {
    @Test("加载、播放和暂停期间保持浮窗，不安排自动收起")
    func activePlaybackRemainsVisible() {
        var presentation = TTSFloatingPanelPresentation()
        for status in [TTSPlaybackStatus.buffering, .playing, .paused] {
            presentation.updatePlayback(isSpeaking: false, status: status)
            #expect(presentation.isVisible)
            #expect(presentation.dismissalID == nil)
        }
    }

    @Test("真正结束后才安排收起，同一结束状态不延长倒计时")
    func completedPlaybackSchedulesOneDismissal() throws {
        var presentation = TTSFloatingPanelPresentation()
        presentation.updatePlayback(isSpeaking: true, status: .playing)
        presentation.updatePlayback(isSpeaking: true, status: .ended)
        #expect(presentation.dismissalID == nil)
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        let id = try #require(presentation.dismissalID)
        #expect(presentation.isVisible)
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        #expect(presentation.dismissalID == id)
        presentation.dismiss(ifMatching: id)
        #expect(!presentation.isVisible)
    }

    @Test("重新朗读后旧倒计时不能关闭新浮窗")
    func replayInvalidatesOldDismissal() throws {
        var presentation = TTSFloatingPanelPresentation()
        presentation.updatePlayback(isSpeaking: true, status: .playing)
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        let oldID = try #require(presentation.dismissalID)
        presentation.cancelPendingDismissal()
        presentation.updatePlayback(isSpeaking: true, status: .buffering)
        presentation.dismiss(ifMatching: oldID)
        #expect(presentation.isVisible)
        #expect(presentation.dismissalID == nil)

        presentation.updatePlayback(isSpeaking: false, status: .ended)
        let newID = try #require(presentation.dismissalID)
        #expect(newID != oldID)
        presentation.dismiss(ifMatching: oldID)
        #expect(presentation.isVisible)
        presentation.dismiss(ifMatching: newID)
        #expect(!presentation.isVisible)
    }

    @Test("导出或无障碍操作期间暂停自动收起，操作后重新计时")
    func interactionSuspendsAndRestartsDismissal() throws {
        var presentation = TTSFloatingPanelPresentation()
        presentation.updatePlayback(isSpeaking: true, status: .playing)
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        let oldID = try #require(presentation.dismissalID)
        presentation.setDismissalSuspended(true)
        presentation.dismiss(ifMatching: oldID)
        #expect(presentation.isVisible)
        #expect(presentation.dismissalID == nil)
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        #expect(presentation.dismissalID == nil)

        presentation.setDismissalSuspended(false)
        #expect(presentation.dismissalID != nil)
        #expect(presentation.dismissalID != oldID)
    }

    @Test("朗读失败保留重试入口，关闭后不会因状态刷新重弹")
    func errorRemainsVisibleUntilDismissed() {
        var presentation = TTSFloatingPanelPresentation()
        presentation.updatePlayback(isSpeaking: false, status: .error)
        #expect(presentation.isVisible)
        #expect(presentation.dismissalID == nil)
        presentation.dismiss()
        presentation.updatePlayback(isSpeaking: false, status: .error)
        #expect(!presentation.isVisible)
    }

    @Test("手动停止立即隐藏，但下一次朗读仍会出现")
    func stopAndStartNewPlayback() {
        var presentation = TTSFloatingPanelPresentation()
        presentation.updatePlayback(isSpeaking: true, status: .playing)
        presentation.updatePlayback(isSpeaking: false, status: .idle)
        #expect(!presentation.isVisible)
        #expect(presentation.dismissalID == nil)
        presentation.updatePlayback(isSpeaking: true, status: .playing)
        #expect(presentation.isVisible)
    }

    @Test("新页面不重弹历史完成状态，关闭完成提示后保持隐藏")
    func completedHistoryDoesNotReappear() throws {
        var presentation = TTSFloatingPanelPresentation()
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        #expect(!presentation.isVisible)
        #expect(presentation.dismissalID == nil)

        presentation.updatePlayback(isSpeaking: true, status: .playing)
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        let id = try #require(presentation.dismissalID)
        presentation.dismiss()
        presentation.dismiss(ifMatching: id)
        presentation.updatePlayback(isSpeaking: false, status: .ended)
        #expect(!presentation.isVisible)
        #expect(presentation.dismissalID == nil)
    }
}
