import Foundation
import Testing
@testable import ETOSCore

struct MessageToolCallEditingSupportTests {
    @Test("向导能够检索空消息添加工具调用的格式说明")
    func guideSearchFindsToolEditing() async {
        let results = await GuideKnowledgeService().search("空消息 工具调用 JSON 编辑", limit: 1)
        #expect(results.first?.id == "message-tool-call-editing")
    }

    @Test("编辑格式保留结果、状态及服务商字段，并展开参数对象")
    func roundTrip() throws {
        let call = InternalToolCall(id: "call_1", toolName: "app_show_widget", arguments: #"{"code":"<p>你好</p>"}"#,
            result: "结果", resultDisposition: .completed, providerSpecificFields: ["thought_signature": .string("signature")])
        let json = try MessageToolCallEditingSupport.editableJSON([call])
        let parsed = try MessageToolCallEditingSupport.parse(json)
        #expect(parsed == [call])
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(object.first?["arguments"] is [String: Any])
    }

    @Test("拒绝无效参数、重复 ID 和未知字段，空数组可清空调用")
    func validation() throws {
        #expect(try MessageToolCallEditingSupport.parse("[]").isEmpty)
        for invalid in ["{}", "[", #"[{"id":"a","toolName":"","arguments":{}}]"#,
            #"[{"id":"a","toolName":"tool","arguments":[]}]"#,
            #"[{"id":"a","toolName":"tool","arguments":{},"unknown":1}]"#,
            #"[{"id":"a","toolName":"tool","arguments":{}},{"id":"a","toolName":"tool","arguments":{}}]"#] {
            #expect(throws: MessageToolCallEditingError.self) { try MessageToolCallEditingSupport.parse(invalid) }
        }
    }

    @Test("空助手消息可添加调用，手工填写的结果会进入关联历史")
    func addsToEmptyMessage() throws {
        let original = ChatMessage(role: .assistant, content: "", responseAttemptID: UUID())
        var edited = original
        edited.toolCalls = [call(result: "新结果")]
        let messages = try MessageToolCallEditingSupport.applying(edited, to: [original])
        #expect(messages.count == 2)
        #expect(messages[0].content.isEmpty)
        #expect(messages[1].role == .tool)
        #expect(messages[1].content == "新结果")
        #expect(messages[1].responseAttemptID == original.responseAttemptID)
    }

    @Test("结果修改同步对应工具消息并清除旧 Responses 缓存")
    func updatesPairedResult() throws {
        let original = ChatMessage(role: .assistant, content: "", providerResponseMetadata: ["output": .string("旧缓存")], toolCalls: [call(result: "旧结果")])
        let tool = ChatMessage(role: .tool, content: "旧结果", toolCalls: original.toolCalls)
        var edited = original
        edited.toolCalls = [call(result: "新结果")]
        let messages = try MessageToolCallEditingSupport.applying(edited, to: [original, tool])
        #expect(messages.count == 2)
        #expect(messages[0].providerResponseMetadata == nil)
        #expect(messages[1].id == tool.id)
        #expect(messages[1].content == "新结果")
        #expect(messages[1].toolCalls?.first?.result == "新结果")
    }

    @Test("删除调用只移除本次回复的对应结果，不影响其他尝试或轮次")
    func removesOnlyRelatedResults() throws {
        let original = ChatMessage(role: .assistant, content: "正文", toolCalls: [call(result: "结果")], responseAttemptID: UUID())
        let tool = ChatMessage(role: .tool, content: "结果", toolCalls: original.toolCalls, responseAttemptID: original.responseAttemptID)
        let otherAttempt = ChatMessage(role: .tool, content: "另一尝试", toolCalls: original.toolCalls, responseAttemptID: UUID())
        let nextUser = ChatMessage(role: .user, content: "下一轮")
        let nextResult = ChatMessage(role: .tool, content: "下一轮结果", toolCalls: original.toolCalls)
        var edited = original
        edited.toolCalls = nil
        let messages = try MessageToolCallEditingSupport.applying(edited, to: [original, tool, otherAttempt, nextUser, nextResult])
        #expect(messages.map(\.id) == [original.id, otherAttempt.id, nextUser.id, nextResult.id])
    }

    @Test("从结果气泡修改调用 ID、参数和正文会回写关联助手调用")
    func editsToolResult() throws {
        let originalCall = call(result: "旧结果")
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: [originalCall])
        let original = ChatMessage(role: .tool, content: "旧结果", toolCalls: [originalCall])
        var edited = original
        edited.content = "新结果"
        edited.toolCalls = [InternalToolCall(id: "renamed", toolName: "new_tool", arguments: "{}", result: "旧结果")]
        let messages = try MessageToolCallEditingSupport.applying(edited, to: [assistant, original])
        #expect(messages[0].toolCalls?.first?.id == "renamed")
        #expect(messages[0].toolCalls?.first?.result == "新结果")
        #expect(messages[1].content == "新结果")
    }

    @Test("正文和思考编辑保留未修改的旧工具参数及其他内容版本")
    func preservesUneditedPayload() throws {
        let oldCall = InternalToolCall(id: "a", toolName: "legacy", arguments: "未完成的 JSON")
        var original = ChatMessage(role: .assistant, content: "旧版本", toolCalls: [oldCall])
        original.addVersion("当前版本")
        var edited = original
        edited.content = "修改后的版本"
        edited.reasoningContent = "修改后的思考"
        let saved = try #require(MessageToolCallEditingSupport.applying(edited, to: [original]).first)
        #expect(saved.getAllVersions() == ["旧版本", "修改后的版本"])
        #expect(saved.toolCalls == [oldCall])
    }

    private func call(result: String?) -> InternalToolCall {
        InternalToolCall(id: "call_1", toolName: "app_show_widget", arguments: "{}", result: result)
    }
}
