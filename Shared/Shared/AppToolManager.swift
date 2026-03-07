// ============================================================================
// AppToolManager.swift
// ============================================================================
// 本地拓展工具管理器。
// - 管理默认关闭的本地拓展工具目录
// - 负责聊天工具暴露与执行分发
// ============================================================================

import Foundation
import os.log

public enum AppToolKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case echoText = "echo_text"
    case editMemory = "edit_memory"
    case listSandboxDirectory = "list_sandbox_directory"
    case readSandboxFile = "read_sandbox_file"
    case writeSandboxFile = "write_sandbox_file"
    case searchSandboxFiles = "search_sandbox_files"
    case readSandboxFileChunk = "read_sandbox_file_chunk"
    case moveSandboxItem = "move_sandbox_item"
    case diffSandboxFile = "diff_sandbox_file"
    case editSandboxFile = "edit_sandbox_file"
    case deleteSandboxItem = "delete_sandbox_item"

    public var id: String { rawValue }

    public var toolName: String {
        switch self {
        case .echoText:
            return "app_echo_text"
        case .editMemory:
            return "app_edit_memory"
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
        case .echoText:
            return NSLocalizedString("示例：文本回显", comment: "Example echo tool name")
        case .editMemory:
            return NSLocalizedString("记忆编辑", comment: "Memory edit tool name")
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
        case .echoText:
            return NSLocalizedString("把传入文本原样返回，用于验证拓展工具链路是否正常。", comment: "Example echo tool summary")
        case .editMemory:
            return NSLocalizedString("按记忆 ID 编辑既有记忆内容，并在需要时自动重新嵌入。", comment: "Memory edit tool summary")
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
        case .echoText:
            return NSLocalizedString("示例工具详情：文本回显", comment: "Example echo tool detail description")
        case .editMemory:
            return NSLocalizedString("工具详情：记忆编辑", comment: "Memory edit tool detail description")
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
        case .echoText:
            return NSLocalizedString(
                "示例工具：把 text 参数中的文本原样返回，仅用于验证本地拓展工具链路与参数生成是否正常。",
                comment: "Example echo tool description sent to model"
            )
        case .editMemory:
            return NSLocalizedString(
                "编辑既有长期记忆。可按 memory_id 修改 content，也可切换归档状态。修改 content 后会自动重新生成这条记忆的嵌入。",
                comment: "Memory edit tool description sent to model"
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

public enum AppToolExecutionError: LocalizedError {
    case toolGroupDisabled
    case toolDisabled(String)
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

    private nonisolated static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppToolManager")
    private nonisolated static let chatToolsEnabledUserDefaultsKey = "appTools.chatToolsEnabled"
    private nonisolated static let enabledToolIDsUserDefaultsKey = "appTools.enabledToolIDs"

    @Published public private(set) var chatToolsEnabled: Bool
    @Published private var enabledToolIDs: Set<String>

    private init(defaults: UserDefaults = .standard) {
        chatToolsEnabled = defaults.object(forKey: Self.chatToolsEnabledUserDefaultsKey) as? Bool ?? true
        let storedIDs = defaults.stringArray(forKey: Self.enabledToolIDsUserDefaultsKey) ?? []
        enabledToolIDs = Set(storedIDs.filter { AppToolKind(rawValue: $0) != nil })
    }

    public nonisolated static func isAppToolName(_ name: String) -> Bool {
        AppToolKind.resolve(from: name) != nil
    }

    public var tools: [AppToolCatalogItem] {
        AppToolKind.allCases.map { kind in
            AppToolCatalogItem(kind: kind, isEnabled: enabledToolIDs.contains(kind.rawValue))
        }
    }

    internal var enabledToolKinds: Set<AppToolKind> {
        Set(enabledToolIDs.compactMap(AppToolKind.init(rawValue:)))
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

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        return tools
            .filter(\.isEnabled)
            .map { item in
                InternalToolDefinition(
                    name: item.kind.toolName,
                    description: item.kind.toolDescription,
                    parameters: item.kind.parameters,
                    isBlocking: false
                )
            }
    }

    public func displayLabel(for toolName: String) -> String? {
        AppToolKind.resolve(from: toolName)?.displayName
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard chatToolsEnabled else {
            throw AppToolExecutionError.toolGroupDisabled
        }
        guard let kind = AppToolKind.resolve(from: toolName) else {
            throw AppToolExecutionError.unknownTool
        }
        guard isToolEnabled(kind) else {
            throw AppToolExecutionError.toolDisabled(kind.displayName)
        }

        switch kind {
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
        case .listSandboxDirectory:
            struct ListDirectoryArgs: Decodable {
                let path: String?
            }

            let argsData = argumentsJSON.data(using: .utf8)
            let args = argsData.flatMap { try? JSONDecoder().decode(ListDirectoryArgs.self, from: $0) }
            let relativePath = args?.path ?? ""
            let items = try SandboxFileToolSupport.listDirectory(relativePath: relativePath)
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

            let content = try SandboxFileToolSupport.readTextFile(relativePath: args.path)
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

            let result = try SandboxFileToolSupport.writeTextFile(
                relativePath: args.path,
                content: args.content,
                createIntermediateDirectories: args.create_parent_directories ?? true
            )
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
            let results = try SandboxFileToolSupport.searchItems(
                relativePath: relativePath,
                nameQuery: args?.name_query,
                contentQuery: args?.content_query,
                maxResults: args?.max_results ?? 20,
                includeDirectories: args?.include_directories ?? false,
                caseSensitive: args?.case_sensitive ?? false
            )
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

            let result = try SandboxFileToolSupport.readTextFileChunk(
                relativePath: args.path,
                startLine: args.start_line ?? 1,
                maxLines: args.max_lines ?? 200
            )
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

            let result = try SandboxFileToolSupport.moveItem(
                from: args.source_path,
                to: args.destination_path,
                overwrite: args.overwrite ?? false,
                createIntermediateDirectories: args.create_parent_directories ?? true
            )
            let payload: [String: Any] = [
                "sourcePath": result.sourcePath,
                "destinationPath": result.destinationPath,
                "wasDirectory": result.wasDirectory,
                "createdParentDirectories": result.createdParentDirectories,
                "overwroteDestination": result.overwroteDestination
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

            return try SandboxFileToolSupport.diffTextFile(
                relativePath: args.path,
                updatedContent: args.updated_content
            )
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

            let result = try SandboxFileToolSupport.replaceText(
                relativePath: args.path,
                oldText: args.old_text,
                newText: args.new_text,
                replaceAll: args.replace_all ?? false
            )
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

            let result = try SandboxFileToolSupport.deleteItem(relativePath: args.path)
            let payload: [String: Any] = [
                "path": result.path,
                "wasDirectory": result.wasDirectory
            ]
            return prettyPrintedJSONString(from: payload)
        }
    }

    internal func restoreStateForTests(chatToolsEnabled: Bool, enabledKinds: Set<AppToolKind>) {
        self.chatToolsEnabled = chatToolsEnabled
        enabledToolIDs = Set(enabledKinds.map(\.rawValue))
        UserDefaults.standard.set(chatToolsEnabled, forKey: Self.chatToolsEnabledUserDefaultsKey)
        UserDefaults.standard.set(Array(enabledToolIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        objectWillChange.send()
    }

    private func persistEnabledToolIDs() {
        UserDefaults.standard.set(Array(enabledToolIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        objectWillChange.send()
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
