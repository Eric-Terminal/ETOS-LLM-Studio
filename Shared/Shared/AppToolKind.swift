import Foundation
import SQLite3

public enum AppToolKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case showWidget = "show_widget"
    case askUserInput = "ask_user_input"
    case getSystemTime = "get_system_time"
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
        case .getSystemTime:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([:])
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
        case .listSQLiteTables:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "database": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("目标数据库：chat（聊天）、config（配置）、memory（记忆）。", comment: "List SQLite tables database parameter description")),
                        "enum": .array(AppToolSQLiteDatabase.allCases.map { .string($0.rawValue) })
                    ]),
                    "include_internal": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("是否包含 sqlite_ 开头的内部表，默认 false。", comment: "List SQLite tables include internal parameter description"))
                    ]),
                    "include_create_sql": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("是否返回建表 SQL，默认 false。", comment: "List SQLite tables include create sql parameter description"))
                    ])
                ]),
                "required": .array([.string("database")])
            ])
        case .querySQLite:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "database": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("目标数据库：chat（聊天）、config（配置）、memory（记忆）。", comment: "Query SQLite database parameter description")),
                        "enum": .array(AppToolSQLiteDatabase.allCases.map { .string($0.rawValue) })
                    ]),
                    "sql": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("只读 SQL，支持 SELECT / WITH / PRAGMA，且仅允许单条语句。", comment: "Query SQLite sql parameter description"))
                    ]),
                    "parameters": .dictionary([
                        "type": .string("array"),
                        "description": .string(NSLocalizedString("按顺序绑定到 SQL 占位符 ? 的参数数组，支持 string/int/double/bool/null。", comment: "Query SQLite parameters description")),
                        "items": .dictionary([:])
                    ]),
                    "max_rows": .dictionary([
                        "type": .string("integer"),
                        "description": .string(NSLocalizedString("最多返回行数，默认 50，最大 500。", comment: "Query SQLite max rows description"))
                    ])
                ]),
                "required": .array([.string("database"), .string("sql")])
            ])
        case .mutateSQLite:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "database": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("目标数据库：chat（聊天）、config（配置）、memory（记忆）。", comment: "Mutate SQLite database parameter description")),
                        "enum": .array(AppToolSQLiteDatabase.allCases.map { .string($0.rawValue) })
                    ]),
                    "sql": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("写入 SQL，仅支持 INSERT / UPDATE / DELETE / REPLACE，且仅允许单条语句。", comment: "Mutate SQLite sql parameter description"))
                    ]),
                    "parameters": .dictionary([
                        "type": .string("array"),
                        "description": .string(NSLocalizedString("按顺序绑定到 SQL 占位符 ? 的参数数组，支持 string/int/double/bool/null。", comment: "Mutate SQLite parameters description")),
                        "items": .dictionary([:])
                    ]),
                    "allow_without_where": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("当 UPDATE/DELETE 不带 WHERE 时，是否允许执行。默认 false。", comment: "Mutate SQLite allow without where description"))
                    ]),
                    "returning_max_rows": .dictionary([
                        "type": .string("integer"),
                        "description": .string(NSLocalizedString("当 SQL 使用 RETURNING 时，最多返回行数，默认 50，最大 500。", comment: "Mutate SQLite returning max rows description"))
                    ])
                ]),
                "required": .array([.string("database"), .string("sql")])
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
        case .getSystemTime:
            return NSLocalizedString(
                "获取当前设备系统时间。无需参数；当用户询问当前时间、日期或需要实时本地时间线索时调用。",
                comment: "Get system time tool description sent to model"
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
        case .listSQLiteTables:
            return NSLocalizedString(
                "列出指定 SQLite 数据库（chat/config/memory）的表与字段结构，可选返回建表 SQL。",
                comment: "List SQLite tables description sent to model"
            )
        case .querySQLite:
            return NSLocalizedString(
                "执行只读 SQL 查询。database 选择 chat/config/memory；sql 仅支持 SELECT/WITH/PRAGMA 且必须是单条语句；parameters 可选，用于按顺序绑定 ? 占位符；max_rows 默认 50。",
                comment: "Query SQLite description sent to model"
            )
        case .mutateSQLite:
            return NSLocalizedString(
                "执行写入 SQL。database 选择 chat/config/memory；sql 仅支持 INSERT/UPDATE/DELETE/REPLACE 且必须是单条语句；parameters 可选；UPDATE/DELETE 默认要求带 WHERE，除非 allow_without_where=true。",
                comment: "Mutate SQLite description sent to model"
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

    static func resolve(from toolName: String) -> AppToolKind? {
        allCases.first(where: { $0.toolName == toolName })
    }
}
