// ============================================================================
// AppToolManagerTests.swift
// ============================================================================
// AppToolManagerTests 测试文件
// - 覆盖拓展工具默认关闭与旧直曝隔离逻辑
// - 覆盖示例工具执行逻辑
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("拓展工具管理器测试")
struct AppToolManagerTests {

    @MainActor
    @Test("chatToolsForLLM 默认不返回任何拓展工具")
    func testChatToolsForLLMReturnsEmptyByDefault() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        let originalCustomJSTools = manager.customJSTools
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies,
                customJSTools: originalCustomJSTools
            )
        }

        manager.restoreStateForTests(chatToolsEnabled: true, enabledKinds: [], customJSTools: [])

        #expect(manager.chatToolsForLLM().isEmpty)
    }

    @MainActor
    @Test("拓展工具目录包含记忆编辑与沙盒文件工具")
    func testToolCatalogContainsRequestedTools() {
        let kinds = Set(AppToolKind.allCases)

        #expect(kinds.contains(.showWidget))
        #expect(kinds.contains(.askUserInput))
        #expect(kinds.contains(.getSystemTime))
        #expect(kinds.contains(.editMemory))
        #expect(kinds.contains(.submitFeedbackTicket))
        #expect(kinds.contains(.fillUserInput))
        #expect(kinds.contains(.executeJSCJavaScript))
        #expect(kinds.contains(.createCustomJSCJSTool))
        #expect(kinds.contains(.executeWebKitJavaScript))
        #expect(kinds.contains(.createCustomWebKitJSTool))
        #expect(kinds.contains(.listSandboxDirectory))
        #expect(kinds.contains(.readSandboxFile))
        #expect(kinds.contains(.writeSandboxFile))
        #expect(kinds.contains(.searchSandboxFiles))
        #expect(kinds.contains(.readSandboxFileChunk))
        #expect(kinds.contains(.moveSandboxItem))
        #expect(kinds.contains(.copySandboxItem))
        #expect(kinds.contains(.createSandboxDirectory))
        #expect(kinds.contains(.batchEditSandboxFile))
        #expect(kinds.contains(.listMemories))
        #expect(kinds.contains(.listSQLiteTables))
        #expect(kinds.contains(.querySQLite))
        #expect(kinds.contains(.mutateSQLite))
        #expect(kinds.contains(.undoSandboxMutation))
        #expect(kinds.contains(.diffSandboxFile))
        #expect(kinds.contains(.editSandboxFile))
        #expect(kinds.contains(.deleteSandboxItem))
    }

    @Test("显示网页卡片工具只暴露当前平台的 HTML 宿主契约")
    func testShowWidgetToolUsesCurrentPlatformContract() {
        guard case let .dictionary(schema) = AppToolKind.showWidget.parameters,
              case let .dictionary(properties)? = schema["properties"],
              case let .dictionary(widgetCode)? = properties["widget_code"],
              case let .string(widgetCodeDescription)? = widgetCode["description"] else {
            Issue.record("显示网页卡片工具缺少 widget_code 参数说明。")
            return
        }

        let toolDescription = AppToolKind.showWidget.toolDescription
        #if os(watchOS)
        #expect(toolDescription.contains("watchOS"))
        #expect(widgetCodeDescription.contains("watchOS"))
        #expect(!toolDescription.contains("iOS"))
        #expect(!widgetCodeDescription.contains("iOS"))
        #elseif os(iOS)
        #expect(toolDescription.contains("iOS"))
        #expect(widgetCodeDescription.contains("iOS"))
        #expect(!toolDescription.contains("watchOS"))
        #expect(!widgetCodeDescription.contains("watchOS"))
        #else
        #expect(!toolDescription.isEmpty)
        #expect(!widgetCodeDescription.isEmpty)
        #endif
    }

    @Test("创建自定义 JS 工具参数包含验证输入")
    func testCreateCustomJSToolParametersIncludeValidationInput() {
        guard case let .dictionary(schema) = AppToolKind.createCustomJSCJSTool.parameters,
              case let .dictionary(properties)? = schema["properties"],
              case let .dictionary(validationInput)? = properties["validation_input"] else {
            Issue.record("创建自定义 JS 工具缺少 validation_input 参数。")
            return
        }

        #expect(validationInput["type"] == .string("object"))
        #expect(validationInput["additionalProperties"] == .bool(true))
    }

    #if canImport(JavaScriptCore) && !os(watchOS)
    @MainActor
    @Test("创建自定义 JSC 工具会先验证脚本")
    func testCreateCustomJSToolRejectsInvalidScript() async {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        let originalCustomJSTools = manager.customJSTools
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies,
                customJSTools: originalCustomJSTools
            )
        }

        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let toolID = "validation_failure_\(suffix)"
        let argumentsJSON = """
        {
          "tool_id": "\(toolID)",
          "display_name": "验证失败工具",
          "description": "用于确认错误脚本不会被保存。",
          "code": "function main(input) { throw new Error('validation failed'); }",
          "validation_input": {}
        }
        """

        await #expect(throws: AppToolExecutionError.self) {
            _ = try await manager.executeCreateCustomJSTool(
                argumentsJSON: argumentsJSON,
                engine: .javaScriptCore
            )
        }
        #expect(manager.customJSTool(withID: toolID, engine: .javaScriptCore) == nil)
    }
    #endif

    @MainActor
    @Test("启用示例工具后不再通过 AppTool 直接暴露")
    func testChatToolsForLLMDoesNotExposeMigratedAppTools() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        let originalCustomJSTools = manager.customJSTools
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies,
                customJSTools: originalCustomJSTools
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText],
            customJSTools: []
        )

        #expect(manager.chatToolsForLLM().isEmpty)
    }

    @MainActor
    @Test("始终拒绝策略会阻止拓展工具暴露给模型")
    func testAlwaysDenyPolicyHidesToolFromLLMExposure() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        let originalCustomJSTools = manager.customJSTools
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies,
                customJSTools: originalCustomJSTools
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText],
            approvalPolicies: [.echoText: .alwaysDeny],
            customJSTools: []
        )

        #expect(manager.approvalPolicy(for: .echoText) == .alwaysDeny)
        #expect(manager.chatToolsForLLM().isEmpty)
    }

    @MainActor
    @Test("始终拒绝策略会阻止拓展工具执行")
    func testAlwaysDenyPolicyBlocksExecution() async {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText],
            approvalPolicies: [.echoText: .alwaysDeny]
        )

        await #expect(throws: AppToolExecutionError.self) {
            _ = try await manager.executeToolFromChat(
                toolName: AppToolKind.echoText.toolName,
                argumentsJSON: #"{"text":"测试文本"}"#
            )
        }
    }

    @MainActor
    @Test("提交反馈工具在 category 非法时应返回参数错误")
    func testSubmitFeedbackToolRejectsInvalidCategory() async {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.submitFeedbackTicket]
        )

        await #expect(throws: AppToolExecutionError.self) {
            _ = try await manager.executeToolFromChat(
                toolName: AppToolKind.submitFeedbackTicket.toolName,
                argumentsJSON: #"{"category":"oops","title":"标题","detail":"详情"}"#
            )
        }
    }

    @MainActor
    @Test("示例工具会回显传入文本")
    func testExecuteEchoTool() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText]
        )

        let result = try await manager.executeToolFromChat(
            toolName: AppToolKind.echoText.toolName,
            argumentsJSON: #"{"text":"测试文本"}"#
        )

        #expect(result == "文本回显结果：测试文本")
    }

    @MainActor
    @Test("显示网页卡片工具会返回可渲染载荷")
    func testExecuteShowWidgetToolReturnsPayload() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.showWidget]
        )

        let result = try await manager.executeToolFromChat(
            toolName: AppToolKind.showWidget.toolName,
            argumentsJSON: #"{"title":"测试卡片","widget_code":"<div>hello</div>","loading_messages":["渲染中..."]}"#
        )

        guard let data = result.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("show_widget 返回结果不是有效 JSON")
            return
        }

        #expect(json["title"] as? String == "测试卡片")
        #expect(json["widget_code"] as? String == "<div>hello</div>")
        #expect((json["loading_messages"] as? [String]) == ["渲染中..."])
    }

    @MainActor
    @Test("显示网页卡片工具默认免审批并通过内置工具通道暴露")
    func testShowWidgetToolAlwaysAllowWithoutApproval() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.showWidget],
            approvalPolicies: [.showWidget: .alwaysDeny]
        )

        #expect(manager.approvalPolicy(for: .showWidget) == .alwaysAllow)
        #expect(manager.chatToolsForLLM().contains(where: { $0.name == AppToolKind.showWidget.toolName }) == false)
        #expect(manager.builtInToolsForLLM().contains(where: { $0.name == AppToolKind.showWidget.toolName }))

        manager.setToolApprovalPolicy(kind: .showWidget, policy: .alwaysDeny)
        #expect(manager.approvalPolicy(for: .showWidget) == .alwaysAllow)
        #expect(manager.chatToolsForLLM().contains(where: { $0.name == AppToolKind.showWidget.toolName }) == false)
        #expect(manager.builtInToolsForLLM().contains(where: { $0.name == AppToolKind.showWidget.toolName }))
    }

    @MainActor
    @Test("获取系统时间工具默认免审批并使用无参 schema")
    func testGetSystemTimeToolAlwaysAllowWithoutApproval() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: false,
            enabledKinds: [.getSystemTime],
            approvalPolicies: [.getSystemTime: .alwaysDeny]
        )

        #expect(manager.approvalPolicy(for: .getSystemTime) == .alwaysAllow)
        #expect(manager.chatToolsForLLM().contains(where: { $0.name == AppToolKind.getSystemTime.toolName }) == false)

        let tool = try #require(manager.builtInToolsForLLM().first(where: { $0.name == AppToolKind.getSystemTime.toolName }))
        guard case let .dictionary(schema) = tool.parameters,
              case let .dictionary(properties)? = schema["properties"] else {
            Issue.record("获取系统时间工具未提供 object/properties schema。")
            return
        }
        #expect(properties.isEmpty)

        let result = try await manager.executeToolFromChat(
            toolName: AppToolKind.getSystemTime.toolName,
            argumentsJSON: "{}"
        )
        #expect(result.contains("当前系统本地时间"))
        #expect(result.contains("ISO8601"))
    }

    @MainActor
    @Test("显示网页卡片工具在拓展工具总开关关闭时仍可执行")
    func testShowWidgetToolWorksWhenAppToolGroupDisabled() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: false,
            enabledKinds: [.showWidget]
        )

        let result = try await manager.executeToolFromChat(
            toolName: AppToolKind.showWidget.toolName,
            argumentsJSON: #"{"widget_code":"<div>ok</div>"}"#
        )
        #expect(result.contains("\"widget_code\""))
    }

    @MainActor
    @Test("询问用户选项工具默认免审批并通过内置工具通道暴露")
    func testAskUserInputToolAlwaysAllowWithoutApproval() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.askUserInput],
            approvalPolicies: [.askUserInput: .alwaysDeny]
        )

        #expect(manager.approvalPolicy(for: .askUserInput) == .alwaysAllow)
        #expect(manager.chatToolsForLLM().contains(where: { $0.name == AppToolKind.askUserInput.toolName }) == false)
        #expect(manager.builtInToolsForLLM().contains(where: { $0.name == AppToolKind.askUserInput.toolName }))
    }

    @MainActor
    @Test("询问用户选项工具会广播问答请求")
    func testExecuteAskUserInputToolPostsNotification() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.askUserInput]
        )

        var latestRequest: AppToolAskUserInputRequest?
        let observer = NotificationCenter.default.addObserver(
            forName: .appToolAskUserInputRequested,
            object: nil,
            queue: nil
        ) { notification in
            latestRequest = AppToolAskUserInputRequest.decode(from: notification.userInfo)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        _ = try await manager.executeToolFromChat(
            toolName: AppToolKind.askUserInput.toolName,
            argumentsJSON: #"""
            {
              "request_id": "clarify-user",
              "title": "补充问题",
              "submit_label": "继续",
              "questions": [
                {
                  "id": "q1",
                  "question": "你主要要哪一类？",
                  "type": "multi_select",
                  "allow_other": true,
                  "options": [
                    { "id": "o1", "label": "A" },
                    { "id": "o2", "label": "B" }
                  ]
                }
              ]
            }
            """#
        )

        #expect(latestRequest?.requestID == "clarify-user")
        #expect(latestRequest?.title == "补充问题")
        #expect(latestRequest?.submitLabel == "继续")
        #expect(latestRequest?.questions.count == 1)
        #expect(latestRequest?.questions.first?.type == .multiSelect)
        #expect(latestRequest?.questions.first?.allowOther == true)
    }

    @Test("结构化问答策略：单选题输入自定义内容后会锁定选项")
    func testAskUserInputAnswerPolicySingleSelectCustomTextLocksOptions() {
        #expect(
            AppToolAskUserInputAnswerPolicy.canSelectOption(
                type: .singleSelect,
                customText: "  我自己写  "
            ) == false
        )
        #expect(
            AppToolAskUserInputAnswerPolicy.shouldClearSelectedOptionsAfterTypingCustomText(
                type: .singleSelect,
                customText: "自定义答案"
            )
        )
        #expect(
            AppToolAskUserInputAnswerPolicy.hasAnswer(
                selectedOptionIDs: [],
                customText: "自定义答案"
            )
        )
    }

    @Test("结构化问答策略：多选题可同时保留选项与自定义内容")
    func testAskUserInputAnswerPolicyMultiSelectSupportsCombinedAnswer() {
        #expect(
            AppToolAskUserInputAnswerPolicy.canSelectOption(
                type: .multiSelect,
                customText: "我也想补充"
            )
        )
        #expect(
            !AppToolAskUserInputAnswerPolicy.shouldClearSelectedOptionsAfterTypingCustomText(
                type: .multiSelect,
                customText: "我也想补充"
            )
        )
        #expect(
            AppToolAskUserInputAnswerPolicy.hasAnswer(
                selectedOptionIDs: ["option-a"],
                customText: "我也想补充"
            )
        )
    }

    @Test("结构化问答提交格式：使用 Q/A 文本并去除 JSON 负载")
    func testAskUserInputSubmissionFormatterUsesQAFormatWithoutJSONPayload() {
        let request = AppToolAskUserInputRequest(
            requestID: "req-1",
            title: "测试标题",
            description: nil,
            submitLabel: "提交",
            questions: [
                AppToolAskUserInputQuestion(
                    id: "q1",
                    question: "你今天主要想用 Claude 做什么？",
                    type: .multiSelect,
                    options: [
                        .init(id: "o1", label: "写作"),
                        .init(id: "o2", label: "编程"),
                        .init(id: "o3", label: "分析")
                    ],
                    allowOther: true,
                    required: true
                )
            ]
        )
        let submission = AppToolAskUserInputSubmission(
            requestID: "req-1",
            cancelled: false,
            submittedAt: "2026-04-07T14:00:00Z",
            answers: [
                .init(
                    questionID: "q1",
                    question: "你今天主要想用 Claude 做什么？",
                    type: .multiSelect,
                    selectedOptionIDs: ["o2", "o3"],
                    selectedOptionLabels: ["编程", "分析"],
                    otherText: "顺便聊聊产品设计"
                )
            ]
        )

        let content = AppToolAskUserInputSubmissionFormatter.messageContent(
            request: request,
            submission: submission
        )

        #expect(content.contains("Q: 你今天主要想用 Claude 做什么？"))
        #expect(content.contains("A: 编程,分析,顺便聊聊产品设计"))
        #expect(!content.contains("```json"))
        #expect(!content.contains("\"requestID\""))
    }

    @Test("结构化问答提交格式：取消时只返回简短提示")
    func testAskUserInputSubmissionFormatterCancelledMessage() {
        let request = AppToolAskUserInputRequest(
            requestID: "req-cancel",
            title: nil,
            description: nil,
            submitLabel: "提交",
            questions: []
        )
        let submission = AppToolAskUserInputSubmission(
            requestID: "req-cancel",
            cancelled: true,
            submittedAt: "2026-04-07T14:00:00Z",
            answers: []
        )

        let content = AppToolAskUserInputSubmissionFormatter.messageContent(
            request: request,
            submission: submission
        )

        #expect(content == "用户取消了本次问答。")
    }
}
