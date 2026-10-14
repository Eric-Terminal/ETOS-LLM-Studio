import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacRoleplayDataBufferTests {
    @Test("宏表单保留值的空格并拒绝重名、空名和花括号名称")
    func macroRowsValidateWithoutOverwriting() throws {
        let section = MacRoleplayDataSection.macros
        let rows = [MacRoleplayMacroRow(name: " hero ", value: " 名字 "), MacRoleplayMacroRow(name: "place", value: "")]
        #expect(try MacRoleplayDataBuffer.values(text: "", macros: rows, section: section) == ["hero": .string(" 名字 "), "place": .string("")])
        for name in ["hero", " hero ", "Hero", "", "{{name}}"] {
            let invalid = [MacRoleplayMacroRow(name: "hero", value: "甲"), MacRoleplayMacroRow(name: name, value: "乙")]
            #expect(throws: RoleplayDataDraftError.self) { try MacRoleplayDataBuffer.values(text: "", macros: invalid, section: section) }
        }
    }

    @Test("变量仅接受 JSON 对象，向导快照脱敏而原草稿保持完整")
    func variablesAndRedaction() throws {
        let section = MacRoleplayDataSection.variables(.chat)
        let values = try MacRoleplayDataBuffer.values(text: #"{"count":3,"nested":{"enabled":true},"api_key":"SECRET_FOR_TEST"}"#, macros: [], section: section)
        let buffer = MacRoleplayDataBuffer(values: values, section: section)
        #expect(buffer.values["api_key"] == .string("SECRET_FOR_TEST"))
        #expect(!buffer.field.value.prettyPrinted().contains("SECRET_FOR_TEST"))
        #expect(try MacRoleplayDataBuffer.values(text: buffer.text, macros: [], section: section) == values)
        for text in ["[]", "null", "{invalid}"] {
            #expect(throws: MacRoleplayDataError.self) { try MacRoleplayDataBuffer.values(text: text, macros: [], section: section) }
        }
    }

    @Test("消息作用域使用打开时的消息版本，其他作用域不附带消息目标")
    func messageTargetUsesCapturedVersion() {
        var message = ChatMessage(role: .assistant, content: "第一版")
        message.addVersion("第二版")
        #expect(MacRoleplayDataSection.variables(.message).target(message: message) == .variables(.message, messageID: message.id, versionIndex: 1))
        #expect(MacRoleplayDataSection.variables(.chat).target(message: message) == .variables(.chat, messageID: nil, versionIndex: 0))
        #expect(MacRoleplayDataSection.macros.target(message: message) == .macros)
    }
}
