import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacSkillPresentationTests {
    @Test("启用筛选按配置保留被隔离技能，向导明确当前不可调用")
    func isolatedSkillsRemainInEnabledFilter() {
        let source = [SkillMetadata(name: "enabled", description: "one"), SkillMetadata(name: "disabled", description: "two")]
        let (rows, guide) = MacSkillPresentation.prepare(skills: source, enabled: ["enabled"], group: true,
                                                        isolated: true, query: "", enabledOnly: true)
        #expect(rows.map(\.id) == ["enabled"])
        #expect(rows.first?.enabled == true)
        guard case .array(let entries) = guide, case .dictionary(let entry)? = entries.first else {
            Issue.record("技能列表快照缺失"); return
        }
        #expect(entry["available_in_session"] == .bool(false))
        #expect(entry["enabled"] == .bool(true))
    }

    @Test("技能搜索覆盖描述与兼容性，总开关关闭不会清除单项设置")
    func searchesMetadataWithoutChangingSettings() {
        let skills = [SkillMetadata(name: "zeta", description: "browser", compatibility: "Desktop"),
                      SkillMetadata(name: "alpha", description: "review")]
        let (rows, guide) = MacSkillPresentation.prepare(skills: skills, enabled: ["alpha", "zeta"], group: false,
                                                        isolated: false, query: " DESKTOP ", enabledOnly: false)
        #expect(rows.map(\.id) == ["zeta"] && rows.first?.enabled == true)
        guard case .array(let values) = guide, case .dictionary(let first)? = values.first else {
            Issue.record("技能快照不是对象列表"); return
        }
        #expect(first["available_in_session"] == .bool(false))
        let all = MacSkillPresentation.prepare(skills: skills, enabled: [], group: true, isolated: false, query: "", enabledOnly: false)
        #expect(all.0.map(\.id) == ["alpha", "zeta"])
    }
}
