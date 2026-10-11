// ============================================================================
// LocalLinuxToolDefinitions.swift
// ============================================================================
// ETOS LLM Studio
//
// Linux 工具通过内建 MCP 进入现有工具治理链路；这里仅描述模型可见协议。
// ============================================================================

import Foundation

enum LocalLinuxToolName: String, CaseIterable {
    #if os(macOS)
    case run = "native_run"
    case shell = "native_shell"
    case process = "native_process"
    #else
    case run = "linux_run"
    case shell = "linux_shell"
    case process = "linux_process"
    #endif
}

enum LocalLinuxToolDefinitions {
    static var all: [InternalToolDefinition] {
        [run, shell, process]
    }

    static func contains(_ name: String) -> Bool {
        LocalLinuxToolName(rawValue: name) != nil
    }

    static func containsExposedName(_ name: String) -> Bool {
        LocalLinuxToolName.allCases.contains { matchesExposedName(name, tool: $0) }
    }

    static func isCommandExecutionToolExposedName(_ name: String) -> Bool {
        matchesExposedName(name, tool: .run) || matchesExposedName(name, tool: .shell)
    }

    private static func matchesExposedName(_ name: String, tool: LocalLinuxToolName) -> Bool {
        let raw = tool.rawValue
        return name == raw
            || name == "mcp_\(raw)"
            || (name.hasPrefix(MCPManager.toolNamePrefix) && name.hasSuffix("/\(raw)"))
            || (name.hasPrefix(MCPManager.toolAliasPrefix) && name.hasSuffix("_\(raw)"))
    }

    private static var run: InternalToolDefinition {
        InternalToolDefinition(
            name: LocalLinuxToolName.run.rawValue,
            description: runDescription,
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "executable": stringProperty(executableDescription),
                    "arguments": .dictionary([
                        "type": .string("array"),
                        "items": .dictionary(["type": .string("string")]),
                        "description": .string(NSLocalizedString("不含 executable 的参数数组。", comment: "Linux command arguments"))
                    ]),
                    "environment": stringMapProperty(),
                    "working_directory": stringProperty(directoryDescription),
                    "timeout_seconds": numberProperty(NSLocalizedString("可选超时秒数；0 表示不设超时。", comment: "Linux timeout")),
                    "output_limit_bytes": integerProperty(NSLocalizedString("可选原始输出终止阈值；0 表示不设上限。", comment: "Linux output limit"))
                ]),
                "required": .array([.string("executable")])
            ])
        )
    }

    private static var shell: InternalToolDefinition {
        InternalToolDefinition(
            name: LocalLinuxToolName.shell.rawValue,
            description: NSLocalizedString(
                "使用 /bin/sh 执行脚本并等待完成。适合管道、重定向和多条命令；不会静默安装依赖。",
                comment: "Linux shell tool description"
            ),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "script": stringProperty(NSLocalizedString("传给 /bin/sh -lc 的脚本文本。", comment: "Linux shell script")),
                    "environment": stringMapProperty(),
                    "working_directory": stringProperty(directoryDescription),
                    "timeout_seconds": numberProperty(NSLocalizedString("可选超时秒数；0 表示不设超时。", comment: "Linux shell timeout")),
                    "output_limit_bytes": integerProperty(NSLocalizedString("可选原始输出终止阈值；0 表示不设上限。", comment: "Linux shell output limit"))
                ]),
                "required": .array([.string("script")])
            ])
        )
    }

    private static var process: InternalToolDefinition {
        InternalToolDefinition(
            name: LocalLinuxToolName.process.rawValue,
            description: processDescription,
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "action": enumProperty(
                        ["list", "start_terminal", "read_output", "claim_input", "write_stdin", "resize", "interrupt", "cancel", "finish_stdin"],
                        NSLocalizedString("要执行的进程或 PTY 操作。", comment: "Linux process action")
                    ),
                    "job_id": stringProperty(NSLocalizedString("除 list 和 start_terminal 外所需的任务 UUID。", comment: "Linux process job ID")),
                    "input": stringProperty(NSLocalizedString("write_stdin 写入的 UTF-8 文本。", comment: "Linux terminal input")),
                    "columns": integerProperty(NSLocalizedString("PTY 列数。", comment: "Linux terminal columns")),
                    "rows": integerProperty(NSLocalizedString("PTY 行数。", comment: "Linux terminal rows")),
                    "max_bytes": integerProperty(NSLocalizedString("读取模型输出时最多返回的字节数。", comment: "Linux process output maximum")),
                    "cursor": stringProperty(NSLocalizedString("list 返回的已结束任务分页 cursor；活跃任务使用 active_cursor 独立翻页。", comment: "Linux process history cursor")),
                    "history_limit": integerProperty(NSLocalizedString("list 每页返回的已结束任务数，默认 50，最大 200。", comment: "Linux process history page size")),
                    "active_cursor": stringProperty(NSLocalizedString("list 返回的活跃任务分页 cursor；继续翻页不会影响任务运行。", comment: "Linux process active cursor")),
                    "active_limit": integerProperty(NSLocalizedString("list 每页返回的活跃任务数，默认 50，最大 200；这只是响应分页，不是调度上限。", comment: "Linux process active page size"))
                ]),
                "required": .array([.string("action")])
            ])
        )
    }

    private static func stringProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("string"), "description": .string(description)])
    }

    private static var runDescription: String {
        #if os(macOS)
        NSLocalizedString("mac.shell.tool.run", value: "Run a native macOS program and wait for its exit status and bounded output. Missing software is not installed automatically.", comment: "")
        #else
        NSLocalizedString("直接执行 Linux 程序并等待完成，返回退出状态、诊断和有界输出；不会自动安装缺失的软件。", comment: "")
        #endif
    }
    private static var executableDescription: String {
        #if os(macOS)
        NSLocalizedString("mac.shell.tool.executable", value: "A macOS executable path or a command in PATH.", comment: "")
        #else
        NSLocalizedString("Linux 可执行文件路径或 PATH 中的命令名。", comment: "")
        #endif
    }
    private static var directoryDescription: String {
        #if os(macOS)
        NSLocalizedString("mac.shell.tool.directory", value: "Optional absolute macOS working directory; defaults to this conversation's workspace.", comment: "")
        #else
        NSLocalizedString("可选 guest 工作目录；默认使用当前会话工作区。", comment: "")
        #endif
    }
    private static var processDescription: String {
        #if os(macOS)
        NSLocalizedString("mac.shell.tool.process", value: "Manage this conversation's native macOS tasks and PTYs: list, start, read, write, resize, interrupt, cancel or finish input.", comment: "")
        #else
        NSLocalizedString("管理本会话的 Linux 任务和交互式 PTY：列出、启动终端、读取输出、写入、缩放、中断、取消或结束输入。", comment: "")
        #endif
    }

    private static func numberProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("number"), "minimum": .int(0), "description": .string(description)])
    }

    private static func integerProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("integer"), "minimum": .int(0), "description": .string(description)])
    }

    private static func stringMapProperty() -> JSONValue {
        .dictionary([
            "type": .string("object"),
            "additionalProperties": .dictionary(["type": .string("string")]),
            "description": .string(NSLocalizedString("只覆盖本次进程的额外环境变量。", comment: "Linux process environment"))
        ])
    }

    private static func enumProperty(_ values: [String], _ description: String) -> JSONValue {
        .dictionary([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description)
        ])
    }
}
