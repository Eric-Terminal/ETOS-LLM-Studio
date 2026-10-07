import Foundation
import Testing
@testable import ETOSCore

struct ToolInteractionPresentationTests {
    @Test("问答通知直接传值并保留来源，多个窗口只能认领一次")
    func questionnaireDeliveryPreservesIdentity() throws {
        let sessionID = UUID()
        let request = AppToolAskUserInputRequest(
            requestID: "survey", title: "问题", description: nil, submitLabel: "提交",
            questions: [.init(id: "q", question: "请选择", type: .singleSelect,
                              options: [.init(id: "a", label: "选项")], allowOther: true, required: true)],
            sourceSessionID: sessionID, sourceMessageID: UUID()
        )
        let receipt = AppToolUIRequestDeliveryReceipt()
        var userInfo = request.userInfo
        userInfo[AppToolUIRequestDeliveryReceipt.userInfoKey] = receipt
        let decoded = try #require(AppToolAskUserInputRequest.decode(from: userInfo))
        #expect(decoded == request)
        #expect(decoded.sourceSessionID == sessionID)
        let delivered = try #require(AppToolUIRequestDeliveryReceipt.decode(from: userInfo))
        #expect(delivered.claim(.queued))
        #expect(!delivered.claim(.displayed))
        #expect(receipt.delivery == .queued)
    }

    @Test("只有已结束的 Widget 结果可以构建网页，参数和拒绝结果不会执行")
    func widgetRequiresCompletedResult() throws {
        let result = #"{"title":"图表","widget_code":"<p>已完成</p>","inline_aspect_ratio":"4:3"}"#
        let arguments = #"{"widget_code":"<script>unapproved()</script>"}"#
        var call = InternalToolCall(id: "widget", toolName: AppToolKind.showWidget.toolName, arguments: arguments)
        #expect(CompletedToolWidget(message: ChatMessage(role: .assistant, content: "", toolCalls: [call])) == nil)
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: "等待审批", toolCalls: [call])) == nil)
        call.result = result
        call.resultDisposition = .rejected
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: result, toolCalls: [call])) == nil)
        call.resultDisposition = .failed
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: result, toolCalls: [call])) == nil)
        call.resultDisposition = .completed
        let rendered = try #require(CompletedToolWidget(message: ChatMessage(role: .tool, content: result, toolCalls: [call])))
        #expect(rendered.payload.widgetCode == "<p>已完成</p>")
        #expect(!rendered.html.contains("unapproved()"))
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: result))?.payload == rendered.payload)
    }
}
