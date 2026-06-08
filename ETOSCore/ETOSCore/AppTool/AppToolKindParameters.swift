// ============================================================================
// AppToolKindParameters.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具发送给模型的参数 schema。
// ============================================================================

import Foundation

extension AppToolKind {
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
        case .executeJSCJavaScript, .executeWebKitJavaScript:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "code": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要执行的 JavaScript 代码。必须声明同步 function main(input)，返回 JSON 可序列化结果。", comment: "Execute JavaScript code parameter description"))
                    ]),
                    "input": .dictionary([
                        "type": .string("object"),
                        "additionalProperties": .bool(true),
                        "description": .string(NSLocalizedString("传给 main(input) 的 JSON 输入，可为对象、数组、字符串、数字、布尔或 null。", comment: "Execute JavaScript input parameter description"))
                    ])
                ]),
                "required": .array([.string("code")])
            ])
        case .createCustomJSCJSTool, .createCustomWebKitJSTool:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "tool_id": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("自定义工具 ID，可选。仅允许小写字母、数字和下划线；JSC 工具名会是 app_custom_jsc_<tool_id>，WebKit 工具名会是 app_custom_webkit_js_<tool_id>。", comment: "Create custom JS tool id parameter description"))
                    ]),
                    "display_name": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("工具中心显示名称。", comment: "Create custom JS tool display name parameter description"))
                    ]),
                    "description": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("发送给模型的工具用途说明。", comment: "Create custom JS tool description parameter description"))
                    ]),
                    "parameters_schema": .dictionary([
                        "type": .string("object"),
                        "description": .string(NSLocalizedString("该自定义工具的 JSON Schema 参数定义。省略时使用通用 input 字段。", comment: "Create custom JS tool parameters schema parameter description"))
                    ]),
                    "code": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("自定义工具脚本。必须声明同步 function main(input)，不能依赖 Node.js、文件系统或原生网络 API。", comment: "Create custom JS tool code parameter description"))
                    ]),
                    "validation_input": .dictionary([
                        "type": .string("object"),
                        "additionalProperties": .bool(true),
                        "description": .string(NSLocalizedString("创建前试运行 main(input) 的示例 JSON 输入。工具需要必填参数时必须提供一份能通过脚本校验的输入；省略时使用空对象。验证失败则不会保存工具。", comment: "Create custom JS tool validation input parameter description"))
                    ]),
                    "enabled": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("创建后是否启用，默认 true。", comment: "Create custom JS tool enabled parameter description"))
                    ]),
                    "approval_policy": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("审批策略：ask_every_time、always_allow 或 always_deny，默认 ask_every_time。", comment: "Create custom JS tool approval policy parameter description")),
                        "enum": .array([.string("ask_every_time"), .string("always_allow"), .string("always_deny")])
                    ]),
                    "overwrite": .dictionary([
                        "type": .string("boolean"),
                        "description": .string(NSLocalizedString("同 ID 工具存在时是否覆盖，默认 false。", comment: "Create custom JS tool overwrite parameter description"))
                    ])
                ]),
                "required": .array([.string("display_name"), .string("description"), .string("code")])
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
}
