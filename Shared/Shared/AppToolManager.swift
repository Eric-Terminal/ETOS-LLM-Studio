// ============================================================================
// AppToolManager.swift
// ============================================================================
// 本地拓展工具管理器。
// - 管理默认关闭的本地拓展工具目录
// - 负责聊天工具暴露与执行分发
// ============================================================================

import Foundation
import Combine
import os.log

public enum AppToolInputDraftMode: String, Codable, Hashable, Sendable {
    case replace
    case append
}

public struct AppToolInputDraftRequest: Equatable, Sendable {
    public static let textUserInfoKey = "text"
    public static let modeUserInfoKey = "mode"

    public var text: String
    public var mode: AppToolInputDraftMode

    public init(text: String, mode: AppToolInputDraftMode = .replace) {
        self.text = text
        self.mode = mode
    }

    public var userInfo: [AnyHashable: Any] {
        [
            Self.textUserInfoKey: text,
            Self.modeUserInfoKey: mode.rawValue
        ]
    }

    public static func decode(from userInfo: [AnyHashable: Any]?) -> AppToolInputDraftRequest? {
        guard let userInfo,
              let text = userInfo[textUserInfoKey] as? String else {
            return nil
        }
        let modeRawValue = (userInfo[modeUserInfoKey] as? String) ?? AppToolInputDraftMode.replace.rawValue
        let mode = AppToolInputDraftMode(rawValue: modeRawValue) ?? .replace
        return AppToolInputDraftRequest(text: text, mode: mode)
    }
}

public enum AppToolAskUserInputQuestionType: String, Codable, Hashable, Sendable {
    case singleSelect = "single_select"
    case multiSelect = "multi_select"
}

public enum AppToolAskUserInputAnswerPolicy {
    public static func normalizedCustomText(_ rawText: String?) -> String? {
        guard let rawText else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func hasAnswer(selectedOptionIDs: Set<String>, customText: String?) -> Bool {
        !selectedOptionIDs.isEmpty || normalizedCustomText(customText) != nil
    }

    public static func canSelectOption(type: AppToolAskUserInputQuestionType, customText: String?) -> Bool {
        switch type {
        case .singleSelect:
            return normalizedCustomText(customText) == nil
        case .multiSelect:
            return true
        }
    }

    public static func shouldClearSelectedOptionsAfterTypingCustomText(
        type: AppToolAskUserInputQuestionType,
        customText: String?
    ) -> Bool {
        type == .singleSelect && normalizedCustomText(customText) != nil
    }
}

public struct AppToolAskUserInputOption: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct AppToolAskUserInputQuestion: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let question: String
    public let type: AppToolAskUserInputQuestionType
    public let options: [AppToolAskUserInputOption]
    public let allowOther: Bool
    public let required: Bool

    public init(
        id: String,
        question: String,
        type: AppToolAskUserInputQuestionType,
        options: [AppToolAskUserInputOption],
        allowOther: Bool,
        required: Bool
    ) {
        self.id = id
        self.question = question
        self.type = type
        self.options = options
        self.allowOther = allowOther
        self.required = required
    }
}

public struct AppToolAskUserInputRequest: Codable, Identifiable, Equatable, Sendable {
    public static let payloadUserInfoKey = "payload"

    public let requestID: String
    public let title: String?
    public let description: String?
    public let submitLabel: String
    public let questions: [AppToolAskUserInputQuestion]

    public init(
        requestID: String,
        title: String?,
        description: String?,
        submitLabel: String,
        questions: [AppToolAskUserInputQuestion]
    ) {
        self.requestID = requestID
        self.title = title
        self.description = description
        self.submitLabel = submitLabel
        self.questions = questions
    }

    public var id: String { requestID }

    public var userInfo: [AnyHashable: Any] {
        [Self.payloadUserInfoKey: encodedJSONString]
    }

    public static func decode(from userInfo: [AnyHashable: Any]?) -> AppToolAskUserInputRequest? {
        guard let userInfo,
              let payload = userInfo[payloadUserInfoKey] as? String,
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        return request
    }

    private var encodedJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

public struct AppToolAskUserInputQuestionAnswer: Codable, Equatable, Sendable {
    public let questionID: String
    public let question: String
    public let type: AppToolAskUserInputQuestionType
    public let selectedOptionIDs: [String]
    public let selectedOptionLabels: [String]
    public let otherText: String?

    public init(
        questionID: String,
        question: String,
        type: AppToolAskUserInputQuestionType,
        selectedOptionIDs: [String],
        selectedOptionLabels: [String],
        otherText: String?
    ) {
        self.questionID = questionID
        self.question = question
        self.type = type
        self.selectedOptionIDs = selectedOptionIDs
        self.selectedOptionLabels = selectedOptionLabels
        self.otherText = otherText
    }
}

public struct AppToolAskUserInputSubmission: Codable, Equatable, Sendable {
    public let requestID: String
    public let cancelled: Bool
    public let submittedAt: String
    public let answers: [AppToolAskUserInputQuestionAnswer]

    public init(
        requestID: String,
        cancelled: Bool,
        submittedAt: String,
        answers: [AppToolAskUserInputQuestionAnswer]
    ) {
        self.requestID = requestID
        self.cancelled = cancelled
        self.submittedAt = submittedAt
        self.answers = answers
    }
}

public enum AppToolAskUserInputSubmissionFormatter {
    public static func messageContent(
        request: AppToolAskUserInputRequest,
        submission: AppToolAskUserInputSubmission
    ) -> String {
        if submission.cancelled {
            return "用户取消了本次问答。"
        }

        let questionByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
        var blocks: [String] = []
        for answer in submission.answers {
            let answerText = formattedAnswerText(answer, question: questionByID[answer.questionID])
            blocks.append("Q: \(answer.question)\nA: \(answerText)")
        }

        if blocks.isEmpty {
            return "用户未提供回答。"
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func formattedAnswerText(
        _ answer: AppToolAskUserInputQuestionAnswer,
        question: AppToolAskUserInputQuestion?
    ) -> String {
        var segments: [String] = []

        if let question {
            let indexByOptionID = Dictionary(
                uniqueKeysWithValues: question.options.enumerated().map { index, option in
                    (option.id, index + 1)
                }
            )
            let selectedIndexes = answer.selectedOptionIDs.compactMap { optionID in
                indexByOptionID[optionID].map(String.init)
            }
            if !selectedIndexes.isEmpty {
                segments.append(selectedIndexes.joined(separator: ","))
            } else if !answer.selectedOptionLabels.isEmpty {
                segments.append(answer.selectedOptionLabels.joined(separator: ","))
            }
        } else if !answer.selectedOptionLabels.isEmpty {
            segments.append(answer.selectedOptionLabels.joined(separator: ","))
        }

        if let other = AppToolAskUserInputAnswerPolicy.normalizedCustomText(answer.otherText) {
            segments.append(other)
        }

        if segments.isEmpty {
            return "未填写"
        }
        return segments.joined(separator: ",")
    }
}

public extension Notification.Name {
    static let appToolFillUserInputRequested = Notification.Name("com.ETOS.LLM.Studio.appTool.fillUserInput")
    static let appToolAskUserInputRequested = Notification.Name("com.ETOS.LLM.Studio.appTool.askUserInput")
}

public enum AppToolKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case showWidget = "show_widget"
    case askUserInput = "ask_user_input"
    case echoText = "echo_text"
    case fillUserInput = "fill_user_input"
    case editMemory = "edit_memory"
    case submitFeedbackTicket = "submit_feedback_ticket"
    case listSandboxDirectory = "list_sandbox_directory"
    case readSandboxFile = "read_sandbox_file"
    case writeSandboxFile = "write_sandbox_file"
    case searchSandboxFiles = "search_sandbox_files"
    case readSandboxFileChunk = "read_sandbox_file_chunk"
    case moveSandboxItem = "move_sandbox_item"
    case copySandboxItem = "copy_sandbox_item"
    case createSandboxDirectory = "create_sandbox_directory"
    case batchEditSandboxFile = "batch_edit_sandbox_file"
    case listMemories = "list_memories"
    case undoSandboxMutation = "undo_sandbox_mutation"
    case diffSandboxFile = "diff_sandbox_file"
    case editSandboxFile = "edit_sandbox_file"
    case deleteSandboxItem = "delete_sandbox_item"

    public var id: String { rawValue }

    public var requiresApproval: Bool {
        switch self {
        case .showWidget, .askUserInput:
            return false
        default:
            return true
        }
    }

    public var toolName: String {
        switch self {
        case .showWidget:
            return "app_show_widget"
        case .askUserInput:
            return "app_ask_user_input"
        case .echoText:
            return "app_echo_text"
        case .fillUserInput:
            return "app_fill_user_input"
        case .editMemory:
            return "app_edit_memory"
        case .submitFeedbackTicket:
            return "app_submit_feedback_ticket"
        case .listSandboxDirectory:
            return "app_list_sandbox_directory"
        case .readSandboxFile:
            return "app_read_sandbox_file"
        case .writeSandboxFile:
            return "app_write_sandbox_file"
        case .searchSandboxFiles:
            return "app_search_sandbox_files"
        case .readSandboxFileChunk:
            return "app_read_sandbox_file_chunk"
        case .moveSandboxItem:
            return "app_move_sandbox_item"
        case .copySandboxItem:
            return "app_copy_sandbox_item"
        case .createSandboxDirectory:
            return "app_create_sandbox_directory"
        case .batchEditSandboxFile:
            return "app_batch_edit_sandbox_file"
        case .listMemories:
            return "app_list_memories"
        case .undoSandboxMutation:
            return "app_undo_sandbox_mutation"
        case .diffSandboxFile:
            return "app_diff_sandbox_file"
        case .editSandboxFile:
            return "app_edit_sandbox_file"
        case .deleteSandboxItem:
            return "app_delete_sandbox_item"
        }
    }

    public var displayName: String {
        switch self {
        case .showWidget:
            return NSLocalizedString("显示网页卡片", comment: "Show widget tool name")
        case .askUserInput:
            return NSLocalizedString("询问用户选项", comment: "Ask user input tool name")
        case .echoText:
            return NSLocalizedString("示例：文本回显", comment: "Example echo tool name")
        case .fillUserInput:
            return NSLocalizedString("填充输入框", comment: "Fill user input tool name")
        case .editMemory:
            return NSLocalizedString("记忆编辑", comment: "Memory edit tool name")
        case .submitFeedbackTicket:
            return NSLocalizedString("提交反馈工单", comment: "Submit feedback ticket tool name")
        case .listSandboxDirectory:
            return NSLocalizedString("列出沙盒目录", comment: "List sandbox directory tool name")
        case .readSandboxFile:
            return NSLocalizedString("读取沙盒文件", comment: "Read sandbox file tool name")
        case .writeSandboxFile:
            return NSLocalizedString("写入沙盒文件", comment: "Write sandbox file tool name")
        case .searchSandboxFiles:
            return NSLocalizedString("搜索沙盒文件", comment: "Search sandbox files tool name")
        case .readSandboxFileChunk:
            return NSLocalizedString("分块读取沙盒文件", comment: "Read sandbox file chunk tool name")
        case .moveSandboxItem:
            return NSLocalizedString("移动沙盒路径", comment: "Move sandbox item tool name")
        case .copySandboxItem:
            return NSLocalizedString("复制沙盒路径", comment: "Copy sandbox item tool name")
        case .createSandboxDirectory:
            return NSLocalizedString("创建沙盒目录", comment: "Create sandbox directory tool name")
        case .batchEditSandboxFile:
            return NSLocalizedString("批量编辑沙盒文件", comment: "Batch edit sandbox file tool name")
        case .listMemories:
            return NSLocalizedString("列出记忆", comment: "List memories tool name")
        case .undoSandboxMutation:
            return NSLocalizedString("撤销沙盒修改", comment: "Undo sandbox mutation tool name")
        case .diffSandboxFile:
            return NSLocalizedString("比较沙盒文件差异", comment: "Diff sandbox file tool name")
        case .editSandboxFile:
            return NSLocalizedString("局部编辑沙盒文件", comment: "Edit sandbox file tool name")
        case .deleteSandboxItem:
            return NSLocalizedString("删除沙盒路径", comment: "Delete sandbox item tool name")
        }
    }

    public var summary: String {
        switch self {
        case .showWidget:
            return NSLocalizedString("在聊天中渲染可视化网页卡片（Widget）。", comment: "Show widget tool summary")
        case .askUserInput:
            return NSLocalizedString("弹出结构化问答面板，支持单选、多选和“其他输入”。", comment: "Ask user input tool summary")
        case .echoText:
            return NSLocalizedString("把传入文本原样返回，用于验证拓展工具链路是否正常。", comment: "Example echo tool summary")
        case .fillUserInput:
            return NSLocalizedString("把文本放进聊天输入框，支持覆盖或追加。", comment: "Fill user input tool summary")
        case .editMemory:
            return NSLocalizedString("按记忆 ID 编辑既有记忆内容，并在需要时自动重新嵌入。", comment: "Memory edit tool summary")
        case .submitFeedbackTicket:
            return NSLocalizedString("向反馈助手提交问题或建议工单，并返回工单编号与状态。", comment: "Submit feedback ticket tool summary")
        case .listSandboxDirectory:
            return NSLocalizedString("查看应用沙盒 Documents 目录下的文件和子目录。", comment: "List sandbox directory tool summary")
        case .readSandboxFile:
            return NSLocalizedString("读取沙盒内 UTF-8 文本文件内容。", comment: "Read sandbox file tool summary")
        case .writeSandboxFile:
            return NSLocalizedString("写入或覆盖沙盒内 UTF-8 文本文件内容。", comment: "Write sandbox file tool summary")
        case .searchSandboxFiles:
            return NSLocalizedString("按路径名或文本内容搜索沙盒内文件。", comment: "Search sandbox files tool summary")
        case .readSandboxFileChunk:
            return NSLocalizedString("按行号分块读取沙盒文本文件。", comment: "Read sandbox file chunk tool summary")
        case .moveSandboxItem:
            return NSLocalizedString("在沙盒内移动或重命名文件与目录。", comment: "Move sandbox item tool summary")
        case .copySandboxItem:
            return NSLocalizedString("在沙盒内复制文件或目录。", comment: "Copy sandbox item tool summary")
        case .createSandboxDirectory:
            return NSLocalizedString("在沙盒内创建目录结构。", comment: "Create sandbox directory tool summary")
        case .batchEditSandboxFile:
            return NSLocalizedString("按多条规则批量替换沙盒文本文件内容。", comment: "Batch edit sandbox file tool summary")
        case .listMemories:
            return NSLocalizedString("分页查看记忆列表并支持关键词筛选。", comment: "List memories tool summary")
        case .undoSandboxMutation:
            return NSLocalizedString("撤销最近一次沙盒文件修改。", comment: "Undo sandbox mutation tool summary")
        case .diffSandboxFile:
            return NSLocalizedString("比较当前文件内容和拟修改内容之间的差异。", comment: "Diff sandbox file tool summary")
        case .editSandboxFile:
            return NSLocalizedString("按旧文本和新文本对文件做局部替换。", comment: "Edit sandbox file tool summary")
        case .deleteSandboxItem:
            return NSLocalizedString("删除沙盒内的文件或子目录。", comment: "Delete sandbox item tool summary")
        }
    }

    public var detailDescription: String {
        switch self {
        case .showWidget:
            return NSLocalizedString("工具详情：显示网页卡片", comment: "Show widget tool detail description")
        case .askUserInput:
            return NSLocalizedString("工具详情：询问用户选项", comment: "Ask user input tool detail description")
        case .echoText:
            return NSLocalizedString("示例工具详情：文本回显", comment: "Example echo tool detail description")
        case .fillUserInput:
            return NSLocalizedString("工具详情：填充输入框", comment: "Fill user input tool detail description")
        case .editMemory:
            return NSLocalizedString("工具详情：记忆编辑", comment: "Memory edit tool detail description")
        case .submitFeedbackTicket:
            return NSLocalizedString("工具详情：提交反馈工单", comment: "Submit feedback ticket tool detail description")
        case .listSandboxDirectory:
            return NSLocalizedString("工具详情：列出沙盒目录", comment: "List sandbox directory tool detail description")
        case .readSandboxFile:
            return NSLocalizedString("工具详情：读取沙盒文件", comment: "Read sandbox file tool detail description")
        case .writeSandboxFile:
            return NSLocalizedString("工具详情：写入沙盒文件", comment: "Write sandbox file tool detail description")
        case .searchSandboxFiles:
            return NSLocalizedString("工具详情：搜索沙盒文件", comment: "Search sandbox files tool detail description")
        case .readSandboxFileChunk:
            return NSLocalizedString("工具详情：分块读取沙盒文件", comment: "Read sandbox file chunk tool detail description")
        case .moveSandboxItem:
            return NSLocalizedString("工具详情：移动沙盒路径", comment: "Move sandbox item tool detail description")
        case .copySandboxItem:
            return NSLocalizedString("工具详情：复制沙盒路径", comment: "Copy sandbox item tool detail description")
        case .createSandboxDirectory:
            return NSLocalizedString("工具详情：创建沙盒目录", comment: "Create sandbox directory tool detail description")
        case .batchEditSandboxFile:
            return NSLocalizedString("工具详情：批量编辑沙盒文件", comment: "Batch edit sandbox file tool detail description")
        case .listMemories:
            return NSLocalizedString("工具详情：列出记忆", comment: "List memories tool detail description")
        case .undoSandboxMutation:
            return NSLocalizedString("工具详情：撤销沙盒修改", comment: "Undo sandbox mutation tool detail description")
        case .diffSandboxFile:
            return NSLocalizedString("工具详情：比较沙盒文件差异", comment: "Diff sandbox file tool detail description")
        case .editSandboxFile:
            return NSLocalizedString("工具详情：局部编辑沙盒文件", comment: "Edit sandbox file tool detail description")
        case .deleteSandboxItem:
            return NSLocalizedString("工具详情：删除沙盒路径", comment: "Delete sandbox item tool detail description")
        }
    }

    public var parameters: JSONValue {
        switch self {
        case .showWidget:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "title": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("Widget 标题（可选）。", comment: "Show widget tool title parameter description"))
                    ]),
                    "widget_code": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("用于渲染 Widget 的 HTML 片段，可包含 style/script。", comment: "Show widget tool html parameter description"))
                    ]),
                    "loading_messages": .dictionary([
                        "type": .string("array"),
                        "description": .string(NSLocalizedString("渲染中提示文案列表（可选）。", comment: "Show widget tool loading messages parameter description")),
                        "items": .dictionary([
                            "type": .string("string")
                        ])
                    ])
                ]),
                "required": .array([.string("widget_code")])
            ])
        case .askUserInput:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "title": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("问答标题（可选）。", comment: "Ask user input title parameter description"))
                    ]),
                    "description": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("问答说明（可选）。", comment: "Ask user input description parameter description"))
                    ]),
                    "submit_label": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("提交按钮文案（可选，默认“提交”）。", comment: "Ask user input submit label parameter description"))
                    ]),
                    "request_id": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("问答请求 ID（可选，不传会自动生成）。", comment: "Ask user input request id parameter description"))
                    ]),
                    "questions": .dictionary([
                        "type": .string("array"),
                        "description": .string(NSLocalizedString("问题数组，每题支持 single_select 或 multi_select。", comment: "Ask user input questions parameter description")),
                        "items": .dictionary([
                            "type": .string("object"),
                            "properties": .dictionary([
                                "id": .dictionary([
                                    "type": .string("string"),
                                    "description": .string(NSLocalizedString("问题 ID（可选，不传会自动生成）。", comment: "Ask user input question id parameter description"))
                                ]),
                                "question": .dictionary([
                                    "type": .string("string"),
                                    "description": .string(NSLocalizedString("问题文案。", comment: "Ask user input question text parameter description"))
                                ]),
                                "type": .dictionary([
                                    "type": .string("string"),
                                    "description": .string(NSLocalizedString("问题类型：single_select 或 multi_select。", comment: "Ask user input question type parameter description")),
                                    "enum": .array([.string("single_select"), .string("multi_select")])
                                ]),
                                "allow_other": .dictionary([
                                    "type": .string("boolean"),
                                    "description": .string(NSLocalizedString("是否允许“其他输入”，默认 false。", comment: "Ask user input allow other parameter description"))
                                ]),
                                "required": .dictionary([
                                    "type": .string("boolean"),
                                    "description": .string(NSLocalizedString("是否必填，默认 true。", comment: "Ask user input required parameter description"))
                                ]),
                                "options": .dictionary([
                                    "type": .string("array"),
                                    "description": .string(NSLocalizedString("选项数组。", comment: "Ask user input options parameter description")),
                                    "items": .dictionary([
                                        "type": .string("object"),
                                        "properties": .dictionary([
                                            "id": .dictionary([
                                                "type": .string("string"),
                                                "description": .string(NSLocalizedString("选项 ID（可选，不传会自动生成）。", comment: "Ask user input option id parameter description"))
                                            ]),
                                            "label": .dictionary([
                                                "type": .string("string"),
                                                "description": .string(NSLocalizedString("选项显示文本。", comment: "Ask user input option label parameter description"))
                                            ]),
                                            "description": .dictionary([
                                                "type": .string("string"),
                                                "description": .string(NSLocalizedString("选项说明（可选）。", comment: "Ask user input option description parameter description"))
                                            ])
                                        ]),
                                        "required": .array([.string("label")])
                                    ])
                                ])
                            ]),
                            "required": .array([.string("question"), .string("type"), .string("options")])
                        ])
                    ])
                ]),
                "required": .array([.string("questions")])
            ])
        case .echoText:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "text": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要原样返回的文本内容。", comment: "Example echo tool text parameter description"))
                    ])
                ]),
                "required": .array([.string("text")])
            ])
        case .fillUserInput:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "text": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要放入用户输入框的文本内容。", comment: "Fill user input tool text parameter description"))
                    ]),
                    "mode": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("写入模式：replace 表示覆盖输入框，append 表示追加到输入框末尾。默认 replace。", comment: "Fill user input tool mode parameter description")),
                        "enum": .array([.string("replace"), .string("append")])
                    ])
                ]),
                "required": .array([.string("text")])
            ])
        case .editMemory:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "memory_id": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要编辑的记忆 ID，可从 search_memory 的结果里获得。", comment: "Memory edit tool memory id parameter description"))
                    ]),
                    "content": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("编辑后的记忆内容。若不传，则保持原内容不变。", comment: "Memory edit tool content parameter description"))
                    ]),
                    "is_archived": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("是否归档这条记忆。true 表示归档，false 表示恢复激活。", comment: "Memory edit tool archive parameter description"))
                    ])
                ]),
                "required": .array([.string("memory_id")])
            ])
        case .submitFeedbackTicket:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "category": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("反馈类型，可选 bug 或 suggestion，默认 bug。", comment: "Submit feedback ticket category parameter description")),
                        "enum": .array([.string("bug"), .string("suggestion")])
                    ]),
                    "title": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("反馈标题。", comment: "Submit feedback ticket title parameter description"))
                    ]),
                    "detail": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("反馈详细描述。", comment: "Submit feedback ticket detail parameter description"))
                    ]),
                    "reproduction_steps": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("可复现步骤（可选）。", comment: "Submit feedback ticket reproduction steps parameter description"))
                    ]),
                    "expected_behavior": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("预期行为（可选）。", comment: "Submit feedback ticket expected behavior parameter description"))
                    ]),
                    "actual_behavior": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("实际行为（可选）。", comment: "Submit feedback ticket actual behavior parameter description"))
                    ]),
                    "extra_context": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("补充信息（可选）。", comment: "Submit feedback ticket extra context parameter description"))
                    ])
                ]),
                "required": .array([.string("title"), .string("detail")])
            ])
        case .listSandboxDirectory:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要查看的相对路径，基于 Documents 根目录；留空表示根目录。", comment: "List sandbox directory tool path parameter description"))
                    ])
                ])
            ])
        case .readSandboxFile:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要读取的相对文件路径，基于 Documents 根目录。", comment: "Read sandbox file tool path parameter description"))
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        case .writeSandboxFile:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要写入的相对文件路径，基于 Documents 根目录。", comment: "Write sandbox file tool path parameter description"))
                    ]),
                    "content": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要写入的 UTF-8 文本内容。", comment: "Write sandbox file tool content parameter description"))
                    ]),
                    "create_parent_directories": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("父目录不存在时是否自动创建，默认 true。", comment: "Write sandbox file tool create directories parameter description"))
                    ])
                ]),
                "required": .array([.string("path"), .string("content")])
            ])
        case .searchSandboxFiles:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("搜索起点的相对路径，基于 Documents 根目录；留空表示根目录。", comment: "Search sandbox files path parameter description"))
                    ]),
                    "name_query": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("按路径名或文件名匹配的关键词。", comment: "Search sandbox files name query parameter description"))
                    ]),
                    "content_query": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("按 UTF-8 文本内容匹配的关键词。", comment: "Search sandbox files content query parameter description"))
                    ]),
                    "max_results": .dictionary([
                        "type": .string("integer"),
                        "description": .string(NSLocalizedString("返回结果上限，默认 20，最大 200。", comment: "Search sandbox files max results parameter description"))
                    ]),
                    "include_directories": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("是否在结果中包含目录，默认 false。", comment: "Search sandbox files include directories parameter description"))
                    ]),
                    "case_sensitive": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("是否区分大小写，默认 false。", comment: "Search sandbox files case sensitive parameter description"))
                    ])
                ])
            ])
        case .readSandboxFileChunk:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要分块读取的相对文件路径，基于 Documents 根目录。", comment: "Read sandbox file chunk path parameter description"))
                    ]),
                    "start_line": .dictionary([
                        "type": .string("integer"),
                        "description": .string(NSLocalizedString("起始行号（从 1 开始），默认 1。", comment: "Read sandbox file chunk start line parameter description"))
                    ]),
                    "max_lines": .dictionary([
                        "type": .string("integer"),
                        "description": .string(NSLocalizedString("最多读取行数，默认 200，最大 1000。", comment: "Read sandbox file chunk max lines parameter description"))
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        case .moveSandboxItem:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "source_path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要移动的源相对路径，基于 Documents 根目录。", comment: "Move sandbox item source path parameter description"))
                    ]),
                    "destination_path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("目标相对路径，基于 Documents 根目录。", comment: "Move sandbox item destination path parameter description"))
                    ]),
                    "overwrite": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("目标已存在时是否覆盖，默认 false。", comment: "Move sandbox item overwrite parameter description"))
                    ]),
                    "create_parent_directories": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("目标父目录不存在时是否自动创建，默认 true。", comment: "Move sandbox item create directories parameter description"))
                    ])
                ]),
                "required": .array([.string("source_path"), .string("destination_path")])
            ])
        case .copySandboxItem:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "source_path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要复制的源相对路径，基于 Documents 根目录。", comment: "Copy sandbox item source path parameter description"))
                    ]),
                    "destination_path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("复制后的目标相对路径，基于 Documents 根目录。", comment: "Copy sandbox item destination path parameter description"))
                    ]),
                    "overwrite": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("目标已存在时是否覆盖，默认 false。", comment: "Copy sandbox item overwrite parameter description"))
                    ]),
                    "create_parent_directories": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("目标父目录不存在时是否自动创建，默认 true。", comment: "Copy sandbox item create directories parameter description"))
                    ])
                ]),
                "required": .array([.string("source_path"), .string("destination_path")])
            ])
        case .createSandboxDirectory:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要创建的目录相对路径，基于 Documents 根目录。", comment: "Create sandbox directory path parameter description"))
                    ]),
                    "create_parent_directories": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("父目录不存在时是否自动创建，默认 true。", comment: "Create sandbox directory create directories parameter description"))
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        case .batchEditSandboxFile:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要批量编辑的相对文件路径，基于 Documents 根目录。", comment: "Batch edit sandbox file path parameter description"))
                    ]),
                    "rules": .dictionary([
                        "type": .string("array"),
                        "description": .string(NSLocalizedString("批量替换规则数组，每项包含 old_text 与 new_text。", comment: "Batch edit sandbox file rules parameter description")),
                        "items": .dictionary([
                            "type": .string("object"),
                            "properties": .dictionary([
                                "old_text": .dictionary([
                                    "type": .string("string"),
                                    "description": .string(NSLocalizedString("需要被替换的旧文本。", comment: "Batch edit sandbox file rule old text parameter description"))
                                ]),
                                "new_text": .dictionary([
                                    "type": .string("string"),
                                    "description": .string(NSLocalizedString("替换后的新文本。", comment: "Batch edit sandbox file rule new text parameter description"))
                                ])
                            ]),
                            "required": .array([.string("old_text"), .string("new_text")])
                        ])
                    ]),
                    "replace_all": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("每条规则是否替换全部匹配项，默认 false。", comment: "Batch edit sandbox file replace all parameter description"))
                    ]),
                    "ignore_missing": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("规则未命中时是否忽略，默认 false。", comment: "Batch edit sandbox file ignore missing parameter description"))
                    ])
                ]),
                "required": .array([.string("path"), .string("rules")])
            ])
        case .listMemories:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "query": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("按记忆内容模糊匹配的关键词。", comment: "List memories query parameter description"))
                    ]),
                    "include_archived": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("是否包含已归档记忆，默认 true。", comment: "List memories include archived parameter description"))
                    ]),
                    "offset": .dictionary([
                        "type": .string("integer"),
                        "description": .string(NSLocalizedString("分页起始偏移，默认 0。", comment: "List memories offset parameter description"))
                    ]),
                    "limit": .dictionary([
                        "type": .string("integer"),
                        "description": .string(NSLocalizedString("返回数量上限，默认 20，最大 200。", comment: "List memories limit parameter description"))
                    ]),
                    "order": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("排序方向，支持 desc 或 asc，默认 desc。", comment: "List memories order parameter description"))
                    ])
                ])
            ])
        case .undoSandboxMutation:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([:])
            ])
        case .diffSandboxFile:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要比较的相对文件路径，基于 Documents 根目录。", comment: "Diff sandbox file tool path parameter description"))
                    ]),
                    "updated_content": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("准备写入的新文本内容，用于和当前文件内容比较差异。", comment: "Diff sandbox file tool updated content parameter description"))
                    ])
                ]),
                "required": .array([.string("path"), .string("updated_content")])
            ])
        case .editSandboxFile:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要编辑的相对文件路径，基于 Documents 根目录。", comment: "Edit sandbox file tool path parameter description"))
                    ]),
                    "old_text": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("需要在文件中查找并替换的旧文本片段。", comment: "Edit sandbox file tool old text parameter description"))
                    ]),
                    "new_text": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("替换后的新文本片段。", comment: "Edit sandbox file tool new text parameter description"))
                    ]),
                    "replace_all": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("是否替换全部匹配项，默认 false。", comment: "Edit sandbox file tool replace all parameter description"))
                    ])
                ]),
                "required": .array([.string("path"), .string("old_text"), .string("new_text")])
            ])
        case .deleteSandboxItem:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "path": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要删除的相对路径，基于 Documents 根目录。", comment: "Delete sandbox item tool path parameter description"))
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        }
    }

    public var toolDescription: String {
        switch self {
        case .showWidget:
            return NSLocalizedString(
                "把传入的 HTML Widget 渲染为聊天内联网页卡片。title 可选，widget_code 必填，loading_messages 可选。",
                comment: "Show widget tool description sent to model"
            )
        case .askUserInput:
            return NSLocalizedString(
                "向用户展示结构化问答面板。支持 single_select / multi_select、可选的“其他输入”、必填校验与自定义提交按钮文案。此工具用于在回答前收集关键信息，调用后应等待用户补充。",
                comment: "Ask user input tool description sent to model"
            )
        case .echoText:
            return NSLocalizedString(
                "示例工具：把 text 参数中的文本原样返回，仅用于验证本地拓展工具链路与参数生成是否正常。",
                comment: "Example echo tool description sent to model"
            )
        case .fillUserInput:
            return NSLocalizedString(
                "把文本放入用户当前聊天输入框。text 为要填入的内容；mode=replace 会覆盖输入框，mode=append 会追加到末尾。适合为用户准备可编辑的草稿，而不是直接代替用户发送。",
                comment: "Fill user input tool description sent to model"
            )
        case .editMemory:
            return NSLocalizedString(
                "编辑既有长期记忆。可按 memory_id 修改 content，也可切换归档状态。修改 content 后会自动重新生成这条记忆的嵌入。",
                comment: "Memory edit tool description sent to model"
            )
        case .submitFeedbackTicket:
            return NSLocalizedString(
                "向反馈助手提交一条问题或建议工单。title 和 detail 必填；category 可选 bug 或 suggestion（默认 bug）；可附带复现步骤、预期行为、实际行为、补充信息。",
                comment: "Submit feedback ticket tool description sent to model"
            )
        case .listSandboxDirectory:
            return NSLocalizedString(
                "查看应用沙盒 Documents 目录中的文件与子目录。path 留空时表示根目录，只能访问沙盒内部路径。",
                comment: "List sandbox directory description sent to model"
            )
        case .readSandboxFile:
            return NSLocalizedString(
                "读取应用沙盒 Documents 目录中的 UTF-8 文本文件。只能访问沙盒内部路径。",
                comment: "Read sandbox file description sent to model"
            )
        case .writeSandboxFile:
            return NSLocalizedString(
                "写入或覆盖应用沙盒 Documents 目录中的 UTF-8 文本文件。只能访问沙盒内部路径。",
                comment: "Write sandbox file description sent to model"
            )
        case .searchSandboxFiles:
            return NSLocalizedString(
                "按路径名或 UTF-8 文本内容搜索应用沙盒 Documents 目录下的文件。只能访问沙盒内部路径。",
                comment: "Search sandbox files description sent to model"
            )
        case .readSandboxFileChunk:
            return NSLocalizedString(
                "按行号分块读取应用沙盒 Documents 目录中的 UTF-8 文本文件，适合大文件场景。只能访问沙盒内部路径。",
                comment: "Read sandbox file chunk description sent to model"
            )
        case .moveSandboxItem:
            return NSLocalizedString(
                "在应用沙盒 Documents 目录内移动或重命名文件、子目录。只能访问沙盒内部路径。",
                comment: "Move sandbox item description sent to model"
            )
        case .copySandboxItem:
            return NSLocalizedString(
                "在应用沙盒 Documents 目录内复制文件或子目录，可选是否覆盖已有路径。只能访问沙盒内部路径。",
                comment: "Copy sandbox item description sent to model"
            )
        case .createSandboxDirectory:
            return NSLocalizedString(
                "在应用沙盒 Documents 目录内创建目录，可选自动创建父目录。只能访问沙盒内部路径。",
                comment: "Create sandbox directory description sent to model"
            )
        case .batchEditSandboxFile:
            return NSLocalizedString(
                "按多条规则批量编辑应用沙盒 Documents 目录中的 UTF-8 文本文件。只能访问沙盒内部路径。",
                comment: "Batch edit sandbox file description sent to model"
            )
        case .listMemories:
            return NSLocalizedString(
                "分页列出长期记忆并支持关键词筛选，可选择是否包含归档记忆。",
                comment: "List memories description sent to model"
            )
        case .undoSandboxMutation:
            return NSLocalizedString(
                "撤销最近一次由拓展工具造成的沙盒文件修改。",
                comment: "Undo sandbox mutation description sent to model"
            )
        case .diffSandboxFile:
            return NSLocalizedString(
                "比较应用沙盒 Documents 目录中文本文件的当前内容与拟修改内容之间的差异，只能访问沙盒内部路径。",
                comment: "Diff sandbox file description sent to model"
            )
        case .editSandboxFile:
            return NSLocalizedString(
                "按旧文本和新文本对应用沙盒 Documents 目录中的 UTF-8 文本文件做局部替换。只能访问沙盒内部路径。",
                comment: "Edit sandbox file description sent to model"
            )
        case .deleteSandboxItem:
            return NSLocalizedString(
                "删除应用沙盒 Documents 目录中的文件或子目录。只能访问沙盒内部路径，不能删除 Documents 根目录。",
                comment: "Delete sandbox item description sent to model"
            )
        }
    }

    fileprivate static func resolve(from toolName: String) -> AppToolKind? {
        allCases.first(where: { $0.toolName == toolName })
    }
}

public struct AppToolCatalogItem: Identifiable, Equatable, Sendable {
    public let kind: AppToolKind
    public let isEnabled: Bool

    public var id: AppToolKind { kind }

    public init(kind: AppToolKind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

public enum AppToolApprovalPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case askEveryTime = "ask_every_time"
    case alwaysAllow = "always_allow"
    case alwaysDeny = "always_deny"

    public var displayName: String {
        switch self {
        case .askEveryTime:
            return NSLocalizedString("每次询问", comment: "Ask every time approval policy")
        case .alwaysAllow:
            return NSLocalizedString("总是允许", comment: "Always allow approval policy")
        case .alwaysDeny:
            return NSLocalizedString("始终拒绝", comment: "Always deny approval policy")
        }
    }
}

public enum AppToolExecutionError: LocalizedError {
    case toolGroupDisabled
    case toolDisabled(String)
    case toolDeniedByPolicy(String)
    case unknownTool
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .toolGroupDisabled:
            return NSLocalizedString("拓展工具总开关已关闭。", comment: "App tools group disabled")
        case .toolDisabled(let name):
            return String(
                format: NSLocalizedString("拓展工具“%@”当前未启用。", comment: "App tool disabled"),
                name
            )
        case .toolDeniedByPolicy(let name):
            return String(
                format: NSLocalizedString("拓展工具“%@”当前审批策略为始终拒绝。", comment: "App tool denied by approval policy"),
                name
            )
        case .unknownTool:
            return NSLocalizedString("未找到对应的拓展工具。", comment: "Unknown app tool")
        case .invalidArguments(let message):
            return message
        }
    }
}

@MainActor
public final class AppToolManager: ObservableObject {
    public static let shared = AppToolManager()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则工具中心里的总开关、启用态与审批策略不会稳定自动刷新。

    private nonisolated static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppToolManager")
    private nonisolated static let chatToolsEnabledUserDefaultsKey = "appTools.chatToolsEnabled"
    private nonisolated static let enabledToolIDsUserDefaultsKey = "appTools.enabledToolIDs"
    private nonisolated static let toolApprovalPoliciesUserDefaultsKey = "appTools.toolApprovalPolicies"
    #if os(watchOS)
    private nonisolated static let defaultEnabledToolKinds: Set<AppToolKind> = [.askUserInput]
    #else
    private nonisolated static let defaultEnabledToolKinds: Set<AppToolKind> = [.showWidget, .askUserInput]
    #endif
    private nonisolated static let builtInToolKinds: Set<AppToolKind> = [.showWidget, .askUserInput]

    @Published public private(set) var chatToolsEnabled: Bool
    @Published private var enabledToolIDs: Set<String>
    @Published private var toolApprovalPolicies: [String: AppToolApprovalPolicy]

    private init(defaults: UserDefaults = .standard) {
        chatToolsEnabled = defaults.object(forKey: Self.chatToolsEnabledUserDefaultsKey) as? Bool ?? true
        if let storedIDs = defaults.stringArray(forKey: Self.enabledToolIDsUserDefaultsKey) {
            enabledToolIDs = Set(storedIDs.filter { AppToolKind(rawValue: $0) != nil })
        } else {
            let defaultIDs = Set(Self.defaultEnabledToolKinds.map(\.rawValue))
            enabledToolIDs = defaultIDs
            defaults.set(Array(defaultIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        }
        let storedPolicyRawValues = defaults.dictionary(forKey: Self.toolApprovalPoliciesUserDefaultsKey) as? [String: String] ?? [:]
        toolApprovalPolicies = storedPolicyRawValues.reduce(into: [String: AppToolApprovalPolicy]()) { result, pair in
            guard let kind = AppToolKind(rawValue: pair.key) else { return }
            guard kind.requiresApproval else { return }
            guard let policy = AppToolApprovalPolicy(rawValue: pair.value), policy != .askEveryTime else { return }
            result[pair.key] = policy
        }
    }

    public nonisolated static func isAppToolName(_ name: String) -> Bool {
        AppToolKind.resolve(from: name) != nil
    }

    public nonisolated static func isBuiltInToolName(_ name: String) -> Bool {
        guard let kind = AppToolKind.resolve(from: name) else { return false }
        return builtInToolKinds.contains(kind)
    }

    public var tools: [AppToolCatalogItem] {
        AppToolKind.allCases.filter { !Self.builtInToolKinds.contains($0) }.map { kind in
            AppToolCatalogItem(kind: kind, isEnabled: enabledToolIDs.contains(kind.rawValue))
        }
    }

    internal var enabledToolKinds: Set<AppToolKind> {
        Set(enabledToolIDs.compactMap(AppToolKind.init(rawValue:)))
    }

    internal var configuredApprovalPoliciesByKind: [AppToolKind: AppToolApprovalPolicy] {
        toolApprovalPolicies.reduce(into: [AppToolKind: AppToolApprovalPolicy]()) { result, pair in
            guard let kind = AppToolKind(rawValue: pair.key) else { return }
            result[kind] = pair.value
        }
    }

    public func setChatToolsEnabled(_ isEnabled: Bool) {
        guard chatToolsEnabled != isEnabled else { return }
        chatToolsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.chatToolsEnabledUserDefaultsKey)
        Self.logger.info("本地拓展工具总开关已\(isEnabled ? "开启" : "关闭")。")
    }

    public func isToolEnabled(_ kind: AppToolKind) -> Bool {
        enabledToolIDs.contains(kind.rawValue)
    }

    public func setToolEnabled(kind: AppToolKind, isEnabled: Bool) {
        if isEnabled {
            enabledToolIDs.insert(kind.rawValue)
        } else {
            enabledToolIDs.remove(kind.rawValue)
        }
        persistEnabledToolIDs()
        Self.logger.info("拓展工具 \(kind.rawValue, privacy: .public) 已\(isEnabled ? "启用" : "禁用")。")
    }

    public func approvalPolicy(for kind: AppToolKind) -> AppToolApprovalPolicy {
        guard kind.requiresApproval else { return .alwaysAllow }
        return toolApprovalPolicies[kind.rawValue] ?? .askEveryTime
    }

    public func approvalPolicy(for toolName: String) -> AppToolApprovalPolicy? {
        guard let kind = AppToolKind.resolve(from: toolName) else { return nil }
        return approvalPolicy(for: kind)
    }

    public func setToolApprovalPolicy(kind: AppToolKind, policy: AppToolApprovalPolicy) {
        guard kind.requiresApproval else {
            if toolApprovalPolicies[kind.rawValue] != nil {
                toolApprovalPolicies.removeValue(forKey: kind.rawValue)
                persistToolApprovalPolicies()
            }
            return
        }
        if policy == .askEveryTime {
            toolApprovalPolicies.removeValue(forKey: kind.rawValue)
        } else {
            toolApprovalPolicies[kind.rawValue] = policy
        }
        persistToolApprovalPolicies()
        Self.logger.info("拓展工具 \(kind.rawValue, privacy: .public) 审批策略已更新为 \(policy.rawValue, privacy: .public)。")
    }

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        return tools
            .filter(\.isEnabled)
            .filter { approvalPolicy(for: $0.kind) != .alwaysDeny }
            .map { item in toolDefinition(for: item.kind) }
    }

    public func builtInToolsForLLM() -> [InternalToolDefinition] {
        var tools: [InternalToolDefinition] = []
        if isToolEnabled(.showWidget) {
            tools.append(toolDefinition(for: .showWidget))
        }
        if isToolEnabled(.askUserInput) {
            tools.append(toolDefinition(for: .askUserInput))
        }
        return tools
    }

    public func displayLabel(for toolName: String) -> String? {
        AppToolKind.resolve(from: toolName)?.displayName
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard let kind = AppToolKind.resolve(from: toolName) else {
            throw AppToolExecutionError.unknownTool
        }
        if !Self.builtInToolKinds.contains(kind) && !chatToolsEnabled {
            throw AppToolExecutionError.toolGroupDisabled
        }
        guard isToolEnabled(kind) else {
            throw AppToolExecutionError.toolDisabled(kind.displayName)
        }
        if approvalPolicy(for: kind) == .alwaysDeny {
            throw AppToolExecutionError.toolDeniedByPolicy(kind.displayName)
        }

        switch kind {
        case .showWidget:
            struct ShowWidgetArgs: Decodable {
                let title: String?
                let widget_code: String
                let loading_messages: [String]?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(ShowWidgetArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 show_widget 的参数，请提供 widget_code。", comment: "Show widget tool invalid arguments")
                )
            }

            let widgetCode = args.widget_code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !widgetCode.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：show_widget 的 widget_code 不能为空。", comment: "Show widget tool empty widget code")
                )
            }

            let normalizedTitle = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLoadingMessages = (args.loading_messages ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let payload: [String: Any] = [
                "title": normalizedTitle as Any,
                "widget_code": widgetCode,
                "loading_messages": normalizedLoadingMessages
            ]
            return prettyPrintedJSONString(from: payload)
        case .askUserInput:
            struct AskUserInputArgs: Decodable {
                struct Question: Decodable {
                    struct Option: Decodable {
                        let id: String?
                        let label: String
                        let description: String?
                    }

                    let id: String?
                    let question: String
                    let type: String
                    let options: [Option]
                    let allow_other: Bool?
                    let required: Bool?
                }

                let request_id: String?
                let title: String?
                let description: String?
                let submit_label: String?
                let questions: [Question]
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(AskUserInputArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 ask_user_input 的参数，请提供 questions。", comment: "Ask user input tool invalid arguments")
                )
            }

            let normalizedQuestions = args.questions.enumerated().compactMap { questionIndex, question -> AppToolAskUserInputQuestion? in
                let questionText = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !questionText.isEmpty else { return nil }

                let normalizedTypeRaw = question.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let type = AppToolAskUserInputQuestionType(rawValue: normalizedTypeRaw) else { return nil }

                let questionID = Self.normalizedQuestionID(question.id, fallbackIndex: questionIndex)
                var seenOptionIDs: Set<String> = []
                let normalizedOptions = question.options.enumerated().compactMap { optionIndex, option -> AppToolAskUserInputOption? in
                    let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return nil }
                    let baseID = Self.normalizedOptionalText(option.id) ?? "option_\(optionIndex + 1)"
                    let optionID = Self.uniqueIdentifier(from: baseID, seen: &seenOptionIDs)
                    return AppToolAskUserInputOption(
                        id: optionID,
                        label: label,
                        description: Self.normalizedOptionalText(option.description)
                    )
                }
                guard !normalizedOptions.isEmpty else { return nil }

                return AppToolAskUserInputQuestion(
                    id: questionID,
                    question: questionText,
                    type: type,
                    options: normalizedOptions,
                    allowOther: question.allow_other ?? false,
                    required: question.required ?? true
                )
            }

            guard !normalizedQuestions.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：ask_user_input 至少需要一个有效问题，且每个问题都要包含非空 question、合法 type 和非空 options。", comment: "Ask user input tool invalid normalized questions")
                )
            }

            let requestID = Self.normalizedRequestID(args.request_id)
            let request = AppToolAskUserInputRequest(
                requestID: requestID,
                title: Self.normalizedOptionalText(args.title),
                description: Self.normalizedOptionalText(args.description),
                submitLabel: Self.normalizedOptionalText(args.submit_label) ?? NSLocalizedString("提交", comment: "Ask user input default submit label"),
                questions: normalizedQuestions
            )

            NotificationCenter.default.post(
                name: .appToolAskUserInputRequested,
                object: nil,
                userInfo: request.userInfo
            )

            let payload: [String: Any] = [
                "request_id": request.requestID,
                "question_count": request.questions.count,
                "displayed": true,
                "await_user_supplement": true
            ]
            return prettyPrintedJSONString(from: payload)
        case .echoText:
            struct EchoArgs: Decodable {
                let text: String
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(EchoArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 echo_text 的参数，请提供 text 字段。", comment: "Echo tool invalid arguments")
                )
            }

            let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：echo_text 的 text 不能为空。", comment: "Echo tool empty text")
                )
            }

            return String(
                format: NSLocalizedString("文本回显结果：%@", comment: "Echo tool result format"),
                text
            )
        case .fillUserInput:
            struct FillUserInputArgs: Decodable {
                let text: String
                let mode: String?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(FillUserInputArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 fill_user_input 的参数，请提供 text。", comment: "Fill user input tool invalid arguments")
                )
            }

            let content = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：fill_user_input 的 text 不能为空。", comment: "Fill user input tool empty text")
                )
            }

            let mode = AppToolInputDraftMode(rawValue: (args.mode ?? AppToolInputDraftMode.replace.rawValue).lowercased()) ?? .replace
            let request = AppToolInputDraftRequest(text: args.text, mode: mode)
            NotificationCenter.default.post(
                name: .appToolFillUserInputRequested,
                object: nil,
                userInfo: request.userInfo
            )

            let payload: [String: Any] = [
                "mode": mode.rawValue,
                "characterCount": args.text.count,
                "applied": true
            ]
            return prettyPrintedJSONString(from: payload)
        case .editMemory:
            struct EditMemoryArgs: Decodable {
                let memory_id: String
                let content: String?
                let is_archived: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(EditMemoryArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 edit_memory 的参数，请至少提供 memory_id。", comment: "Memory edit tool invalid arguments")
                )
            }

            guard let memoryID = UUID(uuidString: args.memory_id.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 的 memory_id 不是合法的 UUID。", comment: "Memory edit tool invalid memory id")
                )
            }

            let memories = await MemoryManager.shared.getAllMemories()
            guard let existing = memories.first(where: { $0.id == memoryID }) else {
                throw AppToolExecutionError.invalidArguments(
                    String(
                        format: NSLocalizedString("错误：未找到 ID 为 %@ 的记忆。", comment: "Memory edit tool memory not found"),
                        args.memory_id
                    )
                )
            }

            let trimmedContent = args.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasContentUpdate = trimmedContent != nil
            let hasArchiveUpdate = args.is_archived != nil
            guard hasContentUpdate || hasArchiveUpdate else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 至少要提供 content 或 is_archived 中的一个。", comment: "Memory edit tool missing update fields")
                )
            }

            if let trimmedContent, trimmedContent.isEmpty {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 的 content 不能为空字符串。", comment: "Memory edit tool empty content")
                )
            }

            let embeddingConfigured = MemoryManager.shared.isEmbeddingModelConfigured()
            let resultPayload: [String: Any]

            if hasContentUpdate {
                var updated = existing
                updated.content = trimmedContent ?? existing.content
                if let isArchived = args.is_archived {
                    updated.isArchived = isArchived
                }
                await MemoryManager.shared.updateMemory(item: updated)
                resultPayload = [
                    "memory_id": existing.id.uuidString,
                    "content": updated.content,
                    "isArchived": updated.isArchived,
                    "embeddingConfigured": embeddingConfigured,
                    "reembedded": embeddingConfigured
                ]
            } else if let isArchived = args.is_archived {
                if isArchived {
                    await MemoryManager.shared.archiveMemory(existing)
                } else {
                    await MemoryManager.shared.unarchiveMemory(existing)
                }
                resultPayload = [
                    "memory_id": existing.id.uuidString,
                    "content": existing.content,
                    "isArchived": isArchived,
                    "embeddingConfigured": embeddingConfigured,
                    "reembedded": false
                ]
            } else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 至少要提供 content 或 is_archived 中的一个。", comment: "Memory edit tool missing update fields")
                )
            }

            return prettyPrintedJSONString(from: resultPayload)
        case .submitFeedbackTicket:
            struct SubmitFeedbackArgs: Decodable {
                let category: String?
                let title: String
                let detail: String
                let reproduction_steps: String?
                let expected_behavior: String?
                let actual_behavior: String?
                let extra_context: String?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(SubmitFeedbackArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 submit_feedback_ticket 的参数，请至少提供 title 和 detail。", comment: "Submit feedback ticket invalid arguments")
                )
            }

            let normalizedCategoryRaw = args.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let category: FeedbackCategory
            if let normalizedCategoryRaw, !normalizedCategoryRaw.isEmpty {
                guard let parsedCategory = FeedbackCategory(rawValue: normalizedCategoryRaw) else {
                    throw AppToolExecutionError.invalidArguments(
                        NSLocalizedString("错误：submit_feedback_ticket 的 category 仅支持 bug 或 suggestion。", comment: "Submit feedback ticket invalid category")
                    )
                }
                category = parsedCategory
            } else {
                category = .bug
            }

            let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = args.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !detail.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：submit_feedback_ticket 的 title 和 detail 不能为空。", comment: "Submit feedback ticket empty title or detail")
                )
            }

            let draft = FeedbackDraft(
                category: category,
                title: args.title,
                detail: args.detail,
                reproductionSteps: args.reproduction_steps,
                expectedBehavior: args.expected_behavior,
                actualBehavior: args.actual_behavior,
                extraContext: args.extra_context
            )
            let ticket = try await FeedbackService.shared.submit(draft: draft)
            let formatter = ISO8601DateFormatter()
            let payload: [String: Any] = [
                "issueNumber": ticket.issueNumber,
                "category": ticket.category.rawValue,
                "title": ticket.title,
                "status": ticket.lastKnownStatus.rawValue,
                "createdAt": formatter.string(from: ticket.createdAt),
                "publicURL": ticket.publicURL?.absoluteString as Any,
                "moderationBlocked": ticket.moderationBlocked as Any,
                "moderationMessage": ticket.moderationMessage as Any
            ]
            return prettyPrintedJSONString(from: payload)
        case .listSandboxDirectory:
            struct ListDirectoryArgs: Decodable {
                let path: String?
            }

            let argsData = argumentsJSON.data(using: .utf8)
            let args = argsData.flatMap { try? JSONDecoder().decode(ListDirectoryArgs.self, from: $0) }
            let relativePath = args?.path ?? ""
            let items = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.listDirectory(relativePath: relativePath)
            }
            let payload: [String: Any] = [
                "path": relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Documents" : relativePath,
                "items": items.map { item in
                    [
                        "path": item.path,
                        "name": item.name,
                        "isDirectory": item.isDirectory,
                        "size": item.size,
                        "modifiedAt": item.modifiedAt as Any
                    ]
                }
            ]
            return prettyPrintedJSONString(from: payload)
        case .readSandboxFile:
            struct ReadFileArgs: Decodable {
                let path: String
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(ReadFileArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 read_sandbox_file 的参数，请提供 path。", comment: "Read sandbox file invalid arguments")
                )
            }

            let content = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.readTextFile(relativePath: args.path)
            }
            let payload: [String: Any] = [
                "path": args.path,
                "characterCount": content.count,
                "content": content
            ]
            return prettyPrintedJSONString(from: payload)
        case .writeSandboxFile:
            struct WriteFileArgs: Decodable {
                let path: String
                let content: String
                let create_parent_directories: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(WriteFileArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 write_sandbox_file 的参数，请提供 path 和 content。", comment: "Write sandbox file invalid arguments")
                )
            }

            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.writeTextFile(
                    relativePath: args.path,
                    content: args.content,
                    createIntermediateDirectories: args.create_parent_directories ?? true
                )
            }
            refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
            let payload: [String: Any] = [
                "path": result.path,
                "size": result.size,
                "createdParentDirectories": result.createdParentDirectories
            ]
            return prettyPrintedJSONString(from: payload)
        case .searchSandboxFiles:
            struct SearchFilesArgs: Decodable {
                let path: String?
                let name_query: String?
                let content_query: String?
                let max_results: Int?
                let include_directories: Bool?
                let case_sensitive: Bool?
            }

            let argsData = argumentsJSON.data(using: .utf8)
            let args = argsData.flatMap { try? JSONDecoder().decode(SearchFilesArgs.self, from: $0) }
            let relativePath = args?.path ?? ""
            let results = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.searchItems(
                    relativePath: relativePath,
                    nameQuery: args?.name_query,
                    contentQuery: args?.content_query,
                    maxResults: args?.max_results ?? 20,
                    includeDirectories: args?.include_directories ?? false,
                    caseSensitive: args?.case_sensitive ?? false
                )
            }
            let payload: [String: Any] = [
                "path": relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Documents" : relativePath,
                "count": results.count,
                "items": results.map { result in
                    [
                        "path": result.path,
                        "name": result.name,
                        "isDirectory": result.isDirectory,
                        "size": result.size,
                        "modifiedAt": result.modifiedAt as Any,
                        "matchedByName": result.matchedByName,
                        "matchedByContent": result.matchedByContent
                    ]
                }
            ]
            return prettyPrintedJSONString(from: payload)
        case .readSandboxFileChunk:
            struct ReadFileChunkArgs: Decodable {
                let path: String
                let start_line: Int?
                let max_lines: Int?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(ReadFileChunkArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 read_sandbox_file_chunk 的参数，请提供 path。", comment: "Read sandbox file chunk invalid arguments")
                )
            }

            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.readTextFileChunk(
                    relativePath: args.path,
                    startLine: args.start_line ?? 1,
                    maxLines: args.max_lines ?? 200
                )
            }
            let payload: [String: Any] = [
                "path": result.path,
                "startLine": result.startLine,
                "endLine": result.endLine,
                "totalLines": result.totalLines,
                "hasMore": result.hasMore,
                "content": result.content
            ]
            return prettyPrintedJSONString(from: payload)
        case .moveSandboxItem:
            struct MoveItemArgs: Decodable {
                let source_path: String
                let destination_path: String
                let overwrite: Bool?
                let create_parent_directories: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(MoveItemArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 move_sandbox_item 的参数，请提供 source_path 和 destination_path。", comment: "Move sandbox item invalid arguments")
                )
            }

            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.moveItem(
                    from: args.source_path,
                    to: args.destination_path,
                    overwrite: args.overwrite ?? false,
                    createIntermediateDirectories: args.create_parent_directories ?? true
                )
            }
            refreshCurrentSessionMessagesIfNeeded(
                mutatedPaths: [result.sourcePath, result.destinationPath]
            )
            let payload: [String: Any] = [
                "sourcePath": result.sourcePath,
                "destinationPath": result.destinationPath,
                "wasDirectory": result.wasDirectory,
                "createdParentDirectories": result.createdParentDirectories,
                "overwroteDestination": result.overwroteDestination
            ]
            return prettyPrintedJSONString(from: payload)
        case .copySandboxItem:
            struct CopyItemArgs: Decodable {
                let source_path: String
                let destination_path: String
                let overwrite: Bool?
                let create_parent_directories: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(CopyItemArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 copy_sandbox_item 的参数，请提供 source_path 和 destination_path。", comment: "Copy sandbox item invalid arguments")
                )
            }

            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.copyItem(
                    from: args.source_path,
                    to: args.destination_path,
                    overwrite: args.overwrite ?? false,
                    createIntermediateDirectories: args.create_parent_directories ?? true
                )
            }
            refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.destinationPath])
            let payload: [String: Any] = [
                "sourcePath": result.sourcePath,
                "destinationPath": result.destinationPath,
                "wasDirectory": result.wasDirectory,
                "createdParentDirectories": result.createdParentDirectories,
                "overwroteDestination": result.overwroteDestination
            ]
            return prettyPrintedJSONString(from: payload)
        case .createSandboxDirectory:
            struct CreateDirectoryArgs: Decodable {
                let path: String
                let create_parent_directories: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(CreateDirectoryArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 create_sandbox_directory 的参数，请提供 path。", comment: "Create sandbox directory invalid arguments")
                )
            }

            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.createDirectory(
                    relativePath: args.path,
                    createIntermediateDirectories: args.create_parent_directories ?? true
                )
            }
            let payload: [String: Any] = [
                "path": result.path,
                "created": result.created,
                "createdParentDirectories": result.createdParentDirectories
            ]
            return prettyPrintedJSONString(from: payload)
        case .batchEditSandboxFile:
            struct BatchRuleArgs: Decodable {
                let old_text: String
                let new_text: String
            }
            struct BatchEditArgs: Decodable {
                let path: String
                let rules: [BatchRuleArgs]
                let replace_all: Bool?
                let ignore_missing: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(BatchEditArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 batch_edit_sandbox_file 的参数，请提供 path 和 rules。", comment: "Batch edit sandbox file invalid arguments")
                )
            }

            let rules = args.rules.map { rule in
                SandboxBatchEditRule(oldText: rule.old_text, newText: rule.new_text)
            }
            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.batchReplaceText(
                    relativePath: args.path,
                    rules: rules,
                    replaceAll: args.replace_all ?? false,
                    ignoreMissing: args.ignore_missing ?? false
                )
            }
            refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
            let payload: [String: Any] = [
                "path": result.path,
                "replacements": result.replacements,
                "rulesApplied": result.rulesApplied,
                "size": result.size
            ]
            return prettyPrintedJSONString(from: payload)
        case .listMemories:
            struct ListMemoriesArgs: Decodable {
                let query: String?
                let include_archived: Bool?
                let offset: Int?
                let limit: Int?
                let order: String?
            }

            let argsData = argumentsJSON.data(using: .utf8)
            let args = argsData.flatMap { try? JSONDecoder().decode(ListMemoriesArgs.self, from: $0) }

            let includeArchived = args?.include_archived ?? true
            let offset = max(0, args?.offset ?? 0)
            let limit = min(max(1, args?.limit ?? 20), 200)
            let keyword = args?.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sortDescending = (args?.order ?? "desc").lowercased() != "asc"

            let allMemories = await MemoryManager.shared.getAllMemories()
            let filtered = allMemories.filter { memory in
                guard includeArchived || !memory.isArchived else { return false }
                guard !keyword.isEmpty else { return true }
                return memory.content.localizedCaseInsensitiveContains(keyword)
            }

            let sorted = filtered.sorted { lhs, rhs in
                let leftDate = lhs.updatedAt ?? lhs.createdAt
                let rightDate = rhs.updatedAt ?? rhs.createdAt
                if sortDescending {
                    return leftDate > rightDate
                }
                return leftDate < rightDate
            }

            let paged = Array(sorted.dropFirst(offset).prefix(limit))
            let formatter = ISO8601DateFormatter()
            let payload: [String: Any] = [
                "total": sorted.count,
                "offset": offset,
                "limit": limit,
                "items": paged.map { item in
                    [
                        "memory_id": item.id.uuidString,
                        "content": item.content,
                        "isArchived": item.isArchived,
                        "createdAt": formatter.string(from: item.createdAt),
                        "updatedAt": item.updatedAt.map(formatter.string(from:)) as Any
                    ]
                }
            ]
            return prettyPrintedJSONString(from: payload)
        case .undoSandboxMutation:
            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.undoLastMutation()
            }
            let payload: [String: Any] = [
                "operation": result.operation,
                "recordedAt": result.recordedAt
            ]
            return prettyPrintedJSONString(from: payload)
        case .diffSandboxFile:
            struct DiffFileArgs: Decodable {
                let path: String
                let updated_content: String
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(DiffFileArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 diff_sandbox_file 的参数，请提供 path 和 updated_content。", comment: "Diff sandbox file invalid arguments")
                )
            }

            return try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.diffTextFile(
                    relativePath: args.path,
                    updatedContent: args.updated_content
                )
            }
        case .editSandboxFile:
            struct EditFileArgs: Decodable {
                let path: String
                let old_text: String
                let new_text: String
                let replace_all: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(EditFileArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 edit_sandbox_file 的参数，请提供 path、old_text 和 new_text。", comment: "Edit sandbox file invalid arguments")
                )
            }

            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.replaceText(
                    relativePath: args.path,
                    oldText: args.old_text,
                    newText: args.new_text,
                    replaceAll: args.replace_all ?? false
                )
            }
            refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
            let payload: [String: Any] = [
                "path": result.path,
                "replacements": result.replacements,
                "size": result.size
            ]
            return prettyPrintedJSONString(from: payload)
        case .deleteSandboxItem:
            struct DeleteFileArgs: Decodable {
                let path: String
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(DeleteFileArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 delete_sandbox_item 的参数，请提供 path。", comment: "Delete sandbox item invalid arguments")
                )
            }

            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.deleteItem(relativePath: args.path)
            }
            refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
            let payload: [String: Any] = [
                "path": result.path,
                "wasDirectory": result.wasDirectory
            ]
            return prettyPrintedJSONString(from: payload)
        }
    }

    internal func restoreStateForTests(
        chatToolsEnabled: Bool,
        enabledKinds: Set<AppToolKind>,
        approvalPolicies: [AppToolKind: AppToolApprovalPolicy] = [:]
    ) {
        self.chatToolsEnabled = chatToolsEnabled
        enabledToolIDs = Set(enabledKinds.map(\.rawValue))
        toolApprovalPolicies = approvalPolicies.reduce(into: [String: AppToolApprovalPolicy]()) { result, pair in
            guard pair.key.requiresApproval else { return }
            guard pair.value != .askEveryTime else { return }
            result[pair.key.rawValue] = pair.value
        }
        UserDefaults.standard.set(chatToolsEnabled, forKey: Self.chatToolsEnabledUserDefaultsKey)
        UserDefaults.standard.set(Array(enabledToolIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        let rawPolicyValues = toolApprovalPolicies.mapValues(\.rawValue)
        UserDefaults.standard.set(rawPolicyValues, forKey: Self.toolApprovalPoliciesUserDefaultsKey)
        objectWillChange.send()
    }

    internal nonisolated static func runSandboxFileOperationOffMainThread<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func persistEnabledToolIDs() {
        UserDefaults.standard.set(Array(enabledToolIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        objectWillChange.send()
    }

    private func persistToolApprovalPolicies() {
        let rawPolicyValues = toolApprovalPolicies.mapValues(\.rawValue)
        UserDefaults.standard.set(rawPolicyValues, forKey: Self.toolApprovalPoliciesUserDefaultsKey)
        objectWillChange.send()
    }

    private func refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [String]) {
        let currentSessionID = ChatService.shared.currentSessionSubject.value?.id
        guard Self.shouldRefreshCurrentSessionMessages(
            afterMutatingPaths: mutatedPaths,
            currentSessionID: currentSessionID
        ) else {
            return
        }
        ChatService.shared.reloadCurrentSessionMessagesFromPersistence()
        Self.logger.info("检测到当前会话文件被拓展工具修改，已从磁盘刷新会话消息。")
    }

    internal nonisolated static func shouldRefreshCurrentSessionMessages(
        afterMutatingPaths paths: [String],
        currentSessionID: UUID?
    ) -> Bool {
        guard let currentSessionID else { return false }
        let normalizedPaths = Set(paths.compactMap(normalizedSandboxPathForComparison))
        guard !normalizedPaths.isEmpty else { return false }

        let currentID = currentSessionID.uuidString.lowercased()
        let candidates = Set([
            "documents/chatsessions/sessions/\(currentID).json",
            "documents/chatsessions/\(currentID).json"
        ])
        return !normalizedPaths.intersection(candidates).isEmpty
    }

    private nonisolated static func normalizedSandboxPathForComparison(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return nil }

        if components[0].lowercased() == "documents" {
            return components.joined(separator: "/").lowercased()
        }
        return (["Documents"] + components).joined(separator: "/").lowercased()
    }

    private func toolDefinition(for kind: AppToolKind) -> InternalToolDefinition {
        InternalToolDefinition(
            name: kind.toolName,
            description: kind.toolDescription,
            parameters: kind.parameters,
            isBlocking: true
        )
    }

    private nonisolated static func normalizedRequestID(_ rawValue: String?) -> String {
        if let normalized = normalizedOptionalText(rawValue) {
            return normalized
        }
        return UUID().uuidString
    }

    private nonisolated static func normalizedQuestionID(_ rawValue: String?, fallbackIndex: Int) -> String {
        normalizedOptionalText(rawValue) ?? "question_\(fallbackIndex + 1)"
    }

    private nonisolated static func uniqueIdentifier(from candidate: String, seen: inout Set<String>) -> String {
        if !seen.contains(candidate) {
            seen.insert(candidate)
            return candidate
        }
        var suffix = 2
        while true {
            let next = "\(candidate)_\(suffix)"
            if !seen.contains(next) {
                seen.insert(next)
                return next
            }
            suffix += 1
        }
    }

    private nonisolated static func normalizedOptionalText(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func prettyPrintedJSONString(from payload: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8)
                ?? NSLocalizedString("错误：工具结果序列化失败。", comment: "App tool result serialization fallback")
        } catch {
            return NSLocalizedString("错误：工具结果序列化失败。", comment: "App tool result serialization error")
        }
    }
}
