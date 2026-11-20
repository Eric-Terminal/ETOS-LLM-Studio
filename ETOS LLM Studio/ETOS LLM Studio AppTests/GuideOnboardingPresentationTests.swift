import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
struct GuideOnboardingPresentationTests {
    @Test("聊天起步页只公开模型配置状态和两篇入门文档")
    func onboardingUsesReadOnlySetupContext() {
        let page = GuideSetupPresentation.descriptor()
        #expect(page.id == "chat-home")
        #expect(page.tools.isEmpty)
        #expect(page.documents.map(\.id) == ["getting-started-guide", "app-features-tour"])
        let snapshot = GuideSetupPresentation.snapshot()
        #expect(Set(snapshot.fields.keys) == ["setup_state"])
        #expect(snapshot.fields["setup_state"]?.access == .readOnly)
    }

    @Test("粘错的密钥和带凭据的地址不会出现在助手快照中")
    func addressDisclosureFollowsDiagnostics() {
        for address in ["standalone-key", "https://user:password@example.com/v1", "https://example.com/v1?token=private"] {
            let field = GuideProviderAddressDisclosure.field(address, access: .readWrite)
            #expect(field.access == .writeOnly)
            #expect(field.value == .string(GuideSnapshotField.hiddenValue))
            #expect(GuideProviderAddressDisclosure.readable(address) == nil)
        }
        #expect(GuideProviderAddressDisclosure.readable("https://example.com/v1") == "https://example.com/v1")
    }

    @Test("只读工具仅在执行时可见，确认和导航分别按所属消息展示")
    func toolOnlyMessagesHaveNoFinishedCard() {
        var tools = GuideMessageTools()
        tools.pendingIDs = ["read"]
        tools.hasPendingRead = true
        #expect(tools.isVisible(active: true, awaiting: nil))
        #expect(!tools.isVisible(active: false, awaiting: nil))
        #expect(!tools.isVisible(active: false, awaiting: "another-message"))
        tools.pendingIDs = ["proposal"]
        tools.hasPendingRead = false
        #expect(tools.isVisible(active: false, awaiting: "proposal"))
        tools = GuideMessageTools()
        #expect(!tools.isVisible(active: false, awaiting: nil))
        tools.destinations = [.dataImport]
        #expect(tools.isVisible(active: false, awaiting: nil))
    }
}
