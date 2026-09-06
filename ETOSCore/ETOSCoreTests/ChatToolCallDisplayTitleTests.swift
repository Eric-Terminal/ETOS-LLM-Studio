import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("聊天工具任务标题")
struct ChatToolCallDisplayTitleTests {
    @Test("双端共享标题尊重开关且不修改原始工具参数")
    func displaysPreparedTitleOnlyWhenEnabled() async {
        let call = InternalToolCall(
            id: "linux-call",
            toolName: "mcp_local_linux_shell",
            arguments: #"{"__etos_tool_title":"  检查项目文件  ","command":"ls"}"#
        )
        let message = ChatMessage(role: .assistant, content: "", toolCalls: [call])
        let state = ChatMessageRenderState(message: message)
        await state.toolCallTitlePreparationTask?.value

        #expect(state.toolCallDisplayTitle(for: call.id, isEnabled: true) == "检查项目文件")
        #expect(state.toolCallDisplayTitle(for: call.id, isEnabled: false) == nil)
        #expect(state.toolCallDisplayTitle(for: call.id, isEnabled: true) == "检查项目文件")
        #expect(state.message == message)
        #expect(state.visualMessage.toolCalls?.first?.arguments == call.arguments)
    }

    @Test("缺失、空白、类型错误和未完成的标题保留工具名称", arguments: [
        #"{"command":"ls"}"#,
        #"{"__etos_tool_title":" \n "}"#,
        #"{"__etos_tool_title":123}"#,
        #"{"__etos_tool_title":"检查"#
    ])
    func fallsBackWhenTitleIsUnavailable(arguments: String) async {
        let call = InternalToolCall(id: "call", toolName: "mcp_local_linux_shell", arguments: arguments)
        let state = ChatMessageRenderState(message: ChatMessage(role: .assistant, content: "", toolCalls: [call]))
        await state.toolCallTitlePreparationTask?.value

        #expect(state.toolCallDisplayTitle(for: call.id, isEnabled: true) == nil)
    }

    @Test("普通工具参数中的同名字段不会被当作 MCP 任务标题")
    func ignoresNonMCPTitleArguments() async {
        let call = InternalToolCall(
            id: "call",
            toolName: "save_memory",
            arguments: #"{"__etos_tool_title":"不应显示","content":"偏好"}"#
        )
        let state = ChatMessageRenderState(message: ChatMessage(role: .assistant, content: "", toolCalls: [call]))
        await state.toolCallTitlePreparationTask?.value

        #expect(state.toolCallDisplayTitle(for: call.id, isEnabled: true) == nil)
    }

    @Test("切换消息版本会丢弃旧标题，完成和移除调用时正确保留或清除标题")
    func keepsTitlesInSyncWithVisualMessage() async {
        let oldCall = InternalToolCall(
            id: "call",
            toolName: "mcp_local_linux_shell",
            arguments: #"{"__etos_tool_title":"旧任务"}"#
        )
        var message = ChatMessage(role: .assistant, content: "", toolCalls: [oldCall])
        let state = ChatMessageRenderState(message: message)
        let oldPreparation = state.toolCallTitlePreparationTask

        message.toolCalls = [InternalToolCall(
            id: oldCall.id,
            toolName: oldCall.toolName,
            arguments: #"{"__etos_tool_title":"新任务"}"#
        )]
        state.updateVisualMessage(message)
        await state.toolCallTitlePreparationTask?.value
        await oldPreparation?.value
        #expect(state.toolCallDisplayTitle(for: oldCall.id, isEnabled: true) == "新任务")

        message.toolCalls?[0].result = "完成"
        message.toolCalls?[0].resultDisposition = .completed
        state.updateVisualMessage(message)
        #expect(state.toolCallDisplayTitle(for: oldCall.id, isEnabled: true) == "新任务")

        // 清除调用也必须取消尚未完成的解析，防止旧标题在返回主线程后重新出现。
        message.toolCalls = [oldCall]
        state.updateVisualMessage(message)
        let pendingPreparation = state.toolCallTitlePreparationTask
        message.toolCalls = nil
        state.updateVisualMessage(message)
        await pendingPreparation?.value
        #expect(state.toolCallDisplayTitle(for: oldCall.id, isEnabled: true) == nil)
    }
}
