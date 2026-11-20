import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacGuideNavigationTests {
    @Test("每个桌面可用的助手目标均有对应侧栏，二级页面归入原生分类")
    func sectionsMatchSupportedDestinations() {
        for target in GuideNavigationDestination.allCases {
            #expect((target.macSettingsSection != nil) == target.isAvailable(on: "macOS"))
        }
        #expect(GuideNavigationDestination.dataImport.macSettingsSection == .sync)
        #expect(GuideNavigationDestination.networkProxy.macSettingsSection == .general)
        #expect(GuideNavigationDestination.connectionExceptions.macSettingsSection == .security)
        #expect(GuideNavigationDestination.feedbackCenter.macSettingsSection == .extended)
        #expect(GuideNavigationDestination.feedbackCompose.macSettingsSection == .extended)
    }
}
