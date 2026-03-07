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
