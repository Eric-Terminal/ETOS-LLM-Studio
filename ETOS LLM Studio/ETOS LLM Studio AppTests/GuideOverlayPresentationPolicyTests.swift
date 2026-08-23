import Testing
import ETOSCore
@testable import ETOS_LLM_Studio_App

@Suite("页面向导浮层显示策略测试")
struct GuideOverlayPresentationPolicyTests {
    @Test("任何入口进入上下文帮助页面都显示浮层")
    func contextualHelpDoesNotDependOnSettingsNavigationPath() {
        #expect(GuideOverlayPresentationPolicy.shouldPresent(
            isEnabled: true,
            activeMode: .contextualHelp
        ))
    }

    @Test("开关关闭或页面未声明上下文时不显示浮层")
    func disabledOrMissingContextHidesOverlay() {
        #expect(!GuideOverlayPresentationPolicy.shouldPresent(
            isEnabled: false,
            activeMode: .contextualHelp
        ))
        #expect(!GuideOverlayPresentationPolicy.shouldPresent(
            isEnabled: true,
            activeMode: nil
        ))
    }

    @Test("首次模型配置模式不叠加上下文浮层")
    func modelSetupDoesNotShowContextualOverlay() {
        #expect(!GuideOverlayPresentationPolicy.shouldPresent(
            isEnabled: true,
            activeMode: .modelSetup
        ))
    }
}
