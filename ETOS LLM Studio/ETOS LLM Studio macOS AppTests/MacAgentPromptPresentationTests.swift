import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacAgentPromptPresentationTests {
    @Test("提示词摘要在后台准备且根页向导不包含正文")
    func previewAndGuidePrivacy() {
        let content = String(repeating: "说明", count: 100)
        let profile = LocalAgentPromptProfile(title: "  名称  ", content: content)
        let result = MacAgentPromptPresentation.prepare(LocalAgentPromptLibrarySnapshot(profiles: [profile], selectedProfileID: profile.id.uuidString))
        #expect(result.rows[0].title == "名称")
        #expect(result.rows[0].preview.count == 120)
        #expect(result.rows[0].profile.content == content)
        #expect(result.rows[0].isSelected)
        guard case .array(let rows) = result.guideRows, let first = rows.first, case .dictionary(let fields) = first else {
            Issue.record("缺少提示词目录快照"); return
        }
        #expect(Set(fields.keys) == ["id", "title", "enabled", "built_in", "selected"])
        #expect(fields["selected"] == .bool(true))
    }

    @Test("停用或失效的选用项沿用运行时默认项，空说明仍可保存")
    func disabledSelectionFallsBack() {
        let builtin = LocalAgentPromptProfile(id: LocalAgentPromptStore.builtInProfileID, title: "默认", content: "", isBuiltIn: true)
        let disabled = LocalAgentPromptProfile(title: "", content: "", isEnabled: false)
        for selection in [disabled.id.uuidString, UUID().uuidString, ""] {
            let snapshot = LocalAgentPromptLibrarySnapshot(profiles: [disabled, builtin], selectedProfileID: selection)
            let result = MacAgentPromptPresentation.prepare(snapshot)
            #expect(result.selection == selection)
            #expect(result.effectiveSelection == builtin.id.uuidString)
            #expect(!result.rows[0].isSelected)
            #expect(!result.rows[0].title.isEmpty && !result.rows[0].preview.isEmpty)
            #expect(result.rows[1].isSelected)
        }
    }
}
