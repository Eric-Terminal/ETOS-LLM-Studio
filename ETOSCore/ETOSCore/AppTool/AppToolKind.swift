// ============================================================================
// AppToolKind.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具的枚举与基础元数据。
// ============================================================================

import Foundation

public enum AppToolKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case showWidget = "show_widget"
    case askUserInput = "ask_user_input"
    case getSystemTime = "get_system_time"
    case echoText = "echo_text"
    case fillUserInput = "fill_user_input"
    case executeJSCJavaScript = "execute_jsc_javascript"
    case createCustomJSCJSTool = "create_custom_jsc_js_tool"
    case executeWebKitJavaScript = "execute_webkit_javascript"
    case createCustomWebKitJSTool = "create_custom_webkit_js_tool"
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
    case listSQLiteTables = "list_sqlite_tables"
    case querySQLite = "query_sqlite"
    case mutateSQLite = "mutate_sqlite"
    case undoSandboxMutation = "undo_sandbox_mutation"
    case diffSandboxFile = "diff_sandbox_file"
    case editSandboxFile = "edit_sandbox_file"
    case deleteSandboxItem = "delete_sandbox_item"

    public var id: String { rawValue }

    public var requiresApproval: Bool {
        switch self {
        case .showWidget, .askUserInput, .getSystemTime:
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
        case .getSystemTime:
            return "app_get_system_time"
        case .echoText:
            return "app_echo_text"
        case .fillUserInput:
            return "app_fill_user_input"
        case .executeJSCJavaScript:
            return "app_execute_jsc_javascript"
        case .createCustomJSCJSTool:
            return "app_create_custom_jsc_js_tool"
        case .executeWebKitJavaScript:
            return "app_execute_webkit_javascript"
        case .createCustomWebKitJSTool:
            return "app_create_custom_webkit_js_tool"
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
        case .listSQLiteTables:
            return "app_list_sqlite_tables"
        case .querySQLite:
            return "app_query_sqlite"
        case .mutateSQLite:
            return "app_mutate_sqlite"
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
        case .getSystemTime:
            return NSLocalizedString("获取系统时间", comment: "Get system time tool name")
        case .echoText:
            return NSLocalizedString("示例：文本回显", comment: "Example echo tool name")
        case .fillUserInput:
            return NSLocalizedString("填充输入框", comment: "Fill user input tool name")
        case .executeJSCJavaScript:
            return NSLocalizedString("执行 JSC JavaScript", comment: "Execute JSC JavaScript tool name")
        case .createCustomJSCJSTool:
            return NSLocalizedString("创建自定义 JSC 工具", comment: "Create custom JSC JS tool name")
        case .executeWebKitJavaScript:
            return NSLocalizedString("执行 WebKit JavaScript", comment: "Execute WebKit JavaScript tool name")
        case .createCustomWebKitJSTool:
            return NSLocalizedString("创建自定义 WebKit JS 工具", comment: "Create custom WebKit JS tool name")
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
        case .listSQLiteTables:
            return NSLocalizedString("列出数据库表", comment: "List SQLite tables tool name")
        case .querySQLite:
            return NSLocalizedString("查询数据库", comment: "Query SQLite tool name")
        case .mutateSQLite:
            return NSLocalizedString("修改数据库", comment: "Mutate SQLite tool name")
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
        case .getSystemTime:
            return NSLocalizedString("返回当前设备系统时间。", comment: "Get system time tool summary")
        case .echoText:
            return NSLocalizedString("把传入文本原样返回，用于验证拓展工具链路是否正常。", comment: "Example echo tool summary")
        case .fillUserInput:
            return NSLocalizedString("把文本放进聊天输入框，支持覆盖或追加。", comment: "Fill user input tool summary")
        case .executeJSCJavaScript:
            return NSLocalizedString("使用 Apple JavaScriptCore 运行同步 JavaScript 算法。", comment: "Execute JSC JavaScript tool summary")
        case .createCustomJSCJSTool:
            return NSLocalizedString("保存 AI 可复用的 JavaScriptCore 自定义工具。", comment: "Create custom JSC JS tool summary")
        case .executeWebKitJavaScript:
            return NSLocalizedString("使用 watchOS WebKit bridge 运行同步 JavaScript 算法。", comment: "Execute WebKit JavaScript tool summary")
        case .createCustomWebKitJSTool:
            return NSLocalizedString("保存 AI 可复用的 WebKit bridge 自定义工具。", comment: "Create custom WebKit JS tool summary")
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
        case .listSQLiteTables:
            return NSLocalizedString("查看聊天/配置/记忆 SQLite 数据库中的表结构。", comment: "List SQLite tables tool summary")
        case .querySQLite:
            return NSLocalizedString("执行只读 SQL 查询并返回结果行。", comment: "Query SQLite tool summary")
        case .mutateSQLite:
            return NSLocalizedString("执行 INSERT/UPDATE/DELETE 等写入 SQL。", comment: "Mutate SQLite tool summary")
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
        case .getSystemTime:
            return NSLocalizedString("工具详情：获取系统时间", comment: "Get system time tool detail description")
        case .echoText:
            return NSLocalizedString("示例工具详情：文本回显", comment: "Example echo tool detail description")
        case .fillUserInput:
            return NSLocalizedString("工具详情：填充输入框", comment: "Fill user input tool detail description")
        case .executeJSCJavaScript:
            return NSLocalizedString("工具详情：执行 JSC JavaScript", comment: "Execute JSC JavaScript tool detail description")
        case .createCustomJSCJSTool:
            return NSLocalizedString("工具详情：创建自定义 JSC 工具", comment: "Create custom JSC JS tool detail description")
        case .executeWebKitJavaScript:
            return NSLocalizedString("工具详情：执行 WebKit JavaScript", comment: "Execute WebKit JavaScript tool detail description")
        case .createCustomWebKitJSTool:
            return NSLocalizedString("工具详情：创建自定义 WebKit JS 工具", comment: "Create custom WebKit JS tool detail description")
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
        case .listSQLiteTables:
            return NSLocalizedString("工具详情：列出数据库表", comment: "List SQLite tables tool detail description")
        case .querySQLite:
            return NSLocalizedString("工具详情：查询数据库", comment: "Query SQLite tool detail description")
        case .mutateSQLite:
            return NSLocalizedString("工具详情：修改数据库", comment: "Mutate SQLite tool detail description")
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

    public var isAvailableOnCurrentPlatform: Bool {
        switch self {
        case .executeJSCJavaScript, .createCustomJSCJSTool:
            #if canImport(JavaScriptCore) && !os(watchOS)
            return true
            #else
            return false
            #endif
        case .executeWebKitJavaScript, .createCustomWebKitJSTool:
            #if os(watchOS)
            return true
            #else
            return false
            #endif
        default:
            return true
        }
    }

    static func resolve(from toolName: String) -> AppToolKind? {
        allCases.first(where: { $0.toolName == toolName })
    }
}
