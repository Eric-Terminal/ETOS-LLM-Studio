import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacShortcutToolsTests {
    @Test("搜索覆盖系统名称、显示名称与有效描述，筛选不修改启用状态")
    func filtersPreparedRows() {
        let first = ShortcutToolDefinition(name: "System One", metadata: ["displayName": .string("Alpha")],
                                          isEnabled: true, userDescription: "Custom summary")
        let second = ShortcutToolDefinition(name: "Beta", generatedDescription: "Generated summary")
        for query in [" system one ", "ALPHA", "custom"] {
            let result = MacShortcutToolsModel.prepare(tools: [second, first], enabled: true,
                                                      isolated: false, query: query, enabledOnly: false)
            #expect(result.0.map(\.id) == [first.id])
            #expect(result.0.first?.tool == first)
        }
        let all = MacShortcutToolsModel.prepare(tools: [second, first], enabled: true, isolated: false, query: "summary", enabledOnly: false)
        #expect(all.0.map(\.id) == [first.id, second.id])
        let enabled = MacShortcutToolsModel.prepare(tools: [second, first], enabled: false, isolated: true, query: "", enabledOnly: true)
        #expect(enabled.0.map(\.id) == [first.id])
        #expect(enabled.0.first?.tool.isEnabled == true)
    }

    @Test("工具可见状态同时考虑总开关、单项开关与当前会话隔离")
    func computesConversationAvailability() throws {
        for group in [false, true] {
            for isolated in [false, true] {
                for enabled in [false, true] {
                    let tool = ShortcutToolDefinition(name: "Fixture", isEnabled: enabled)
                    let result = MacShortcutToolsModel.prepare(tools: [tool], enabled: group, isolated: isolated, query: "", enabledOnly: false)
                    guard case .array(let rows) = result.1, case .dictionary(let fields)? = rows.first else {
                        Issue.record("缺少工具目录快照"); return
                    }
                    #expect(fields["available_to_model"] == .bool(group && enabled && !isolated))
                    #expect(fields["enabled"] == .bool(enabled))
                    let expectedStatus: String
                    if isolated { expectedStatus = NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "") }
                    else if !group { expectedStatus = NSLocalizedString("快捷指令工具总开关已关闭。", comment: "") }
                    else { expectedStatus = enabled ? NSLocalizedString("已启用", comment: "") : NSLocalizedString("未启用", comment: "") }
                    #expect(result.0.first?.status == expectedStatus)
                }
            }
        }
    }

    @Test("参数仅用于详情展示，任意元数据和描述不进入目录向导快照")
    func guideDoesNotExposeMetadata() throws {
        let tool = ShortcutToolDefinition(name: "Fixture", metadata: [
            "inputSchema": .dictionary(["secret_example": .string("private-schema-value")]),
            "token": .string("private-token")
        ], userDescription: "private-description")
        let result = MacShortcutToolsModel.prepare(tools: [tool], enabled: true, isolated: false, query: "", enabledOnly: false)
        #expect(result.0.first?.schema?.contains("private-schema-value") == true)
        guard case .array(let rows) = result.1, case .dictionary(let fields)? = rows.first else {
            Issue.record("缺少工具目录快照"); return
        }
        #expect(Set(fields.keys) == Set(["id", "name", "display_name", "enabled", "run_mode", "available_to_model"]))
        let encoded = try JSONEncoder().encode(result.1)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("private-"))
    }
}
