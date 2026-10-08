import Foundation
import SwiftUI
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

@MainActor
struct MacProxySettingsTests {
    @Test("代理向导只公开草稿设置，用户名和密码始终不可读")
    func guidePrivacy() throws {
        var draft = NetworkProxyConfiguration(isEnabled: true, host: "proxy.local", username: "private-user", password: "private-password")
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let fields = MacProxyGuideSettings.fields(binding, showsPassword: true)
        let snapshot = GuideDeclarativeSettingsSupport.snapshot(settings: fields)
        #expect(snapshot.fields["username"]?.access == .writeOnly)
        #expect(snapshot.fields["password"]?.access == .writeOnly)
        #expect(snapshot.fields["username"]?.value == .string(GuideSnapshotField.hiddenValue))
        #expect(snapshot.fields["password"]?.value == .string(GuideSnapshotField.hiddenValue))
        #expect(snapshot.fields["password_visible"]?.access == .readOnly)
        #expect(snapshot.fields["editing_mode"]?.value == .string("draft_until_save"))
        let call = InternalToolCall(id: "proposal", toolName: GuideDeclarativeSettingsSupport.toolName, arguments: "{\"password\":\"replacement\"}")
        let proposal = try GuideDeclarativeSettingsSupport.buildProposal(call: call, pageID: "proxy-test", pageTitle: "代理", settings: fields, snapshot: snapshot)
        #expect(proposal.mutations.first?.isSensitive == true)
        #expect(draft.password == "private-password")
        #expect(throws: GuideError.self) {
            try GuideDeclarativeSettingsSupport.execute(proposal: proposal, pageID: "different-page", pageTitle: "代理", settings: fields)
        }
        let execution = try GuideDeclarativeSettingsSupport.execute(proposal: proposal, pageID: "proxy-test", pageTitle: "代理", settings: fields)
        #expect(draft.password == "replacement")
        #expect(draft.username == "private-user")
        #expect(execution.undoProposal == nil)
        #expect(throws: GuideError.self) {
            try GuideDeclarativeSettingsSupport.buildProposal(
                call: InternalToolCall(id: "forbidden", toolName: GuideDeclarativeSettingsSupport.toolName, arguments: "{\"password_visible\":false}"),
                pageID: "proxy-test", pageTitle: "代理", settings: fields, snapshot: snapshot)
        }
    }

    @Test("锁定或恢复暂停清除代理草稿且使旧页面代次失效")
    func suspensionClearsSecrets() async {
        let model = MacGlobalProxyModel()
        let epoch = model.epoch
        model.draft.username = "private-user"; model.draft.password = "private-password"
        model.suspend()
        #expect(model.epoch != epoch); #expect(model.isSuspended); #expect(!model.canEdit)
        #expect(model.draft == NetworkProxyConfiguration())
        model.save()
        await model.waitForPendingWrites()
        #expect(!model.isSaving)
        model.resume()
        #expect(!model.isLoaded)
    }
}
