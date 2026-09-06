import Testing
@testable import ETOSCore

@Suite("TTS 后台继续朗读策略测试")
struct TTSBackgroundPlaybackPolicyTests {
    @Test("后台继续朗读默认关闭且仅保存在本机")
    func settingDefaultsToLocalOptIn() {
        #expect(AppConfigKey.continueTTSPlaybackInBackground.defaultValue == .bool(false))
        #expect(!AppConfigKey.continueTTSPlaybackInBackground.participatesInSync)
    }

    @Test("前台始终允许朗读")
    func foregroundAlwaysAllowsPlayback() {
        #expect(TTSBackgroundPlaybackPolicy.allowsPlayback(
            isApplicationInBackground: false,
            continuePlaybackInBackground: false
        ))
    }

    @Test("后台只在用户开启选项后允许朗读")
    func backgroundRequiresOptIn() {
        #expect(!TTSBackgroundPlaybackPolicy.allowsPlayback(
            isApplicationInBackground: true,
            continuePlaybackInBackground: false
        ))
        #expect(TTSBackgroundPlaybackPolicy.allowsPlayback(
            isApplicationInBackground: true,
            continuePlaybackInBackground: true
        ))
    }
}
