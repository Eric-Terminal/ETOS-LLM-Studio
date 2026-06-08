// ============================================================================
// ToolCatalogSupport.swift
// ============================================================================
// 统一工具中心所需的共享辅助逻辑。
// - 汇总内置工具状态
// - 生成工具参数 Schema 摘要
// - 统一 MCP 工具目录排序
// ============================================================================

import Foundation

public enum ToolCatalogBuiltInToolKind: String, CaseIterable, Identifiable, Sendable {
    case memoryWrite
    case memorySearch
    case widgetCard
    case askUserInput
    case getSystemTime

    public var id: String { rawValue }
}

public enum ToolCatalogBuiltInToolStatusReason: String, Equatable, Sendable {
    case enabled
    case memoryDisabled
    case memoryWriteDisabled
    case activeRetrievalDisabled
    case zeroTopK
    case isolatedByWorldbook
    case widgetDisabled
    case askUserInputDisabled
    case getSystemTimeDisabled
}

public struct ToolCatalogBuiltInToolState: Identifiable, Equatable, Sendable {
    public let kind: ToolCatalogBuiltInToolKind
    public let isConfiguredEnabled: Bool
    public let isAvailableInCurrentSession: Bool
    public let statusReason: ToolCatalogBuiltInToolStatusReason
    public let memoryTopK: Int

    public var id: ToolCatalogBuiltInToolKind { kind }

    public init(
        kind: ToolCatalogBuiltInToolKind,
        isConfiguredEnabled: Bool,
        isAvailableInCurrentSession: Bool,
        statusReason: ToolCatalogBuiltInToolStatusReason,
        memoryTopK: Int = 0
    ) {
        self.kind = kind
        self.isConfiguredEnabled = isConfiguredEnabled
        self.isAvailableInCurrentSession = isAvailableInCurrentSession
        self.statusReason = statusReason
        self.memoryTopK = memoryTopK
    }
}

public enum AppToolCatalogCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case interaction
    case memory
    case file
    case database
    case feedback

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .interaction:
            return NSLocalizedString("基础交互", comment: "App tool interaction category title")
        case .memory:
            return NSLocalizedString("记忆操作", comment: "App tool memory category title")
        case .file:
            return NSLocalizedString("文件操作", comment: "App tool file category title")
        case .database:
            return NSLocalizedString("数据库操作", comment: "App tool database category title")
        case .feedback:
            return NSLocalizedString("反馈工单", comment: "App tool feedback category title")
        }
    }

    public var summary: String {
        switch self {
        case .interaction:
            return NSLocalizedString("让模型准备草稿或验证本地工具链路。", comment: "App tool interaction category summary")
        case .memory:
            return NSLocalizedString("查看、编辑和归档长期记忆。", comment: "App tool memory category summary")
        case .file:
            return NSLocalizedString("访问与修改应用沙盒 Documents 文件。", comment: "App tool file category summary")
        case .database:
            return NSLocalizedString("查看表结构、查询或受限修改 SQLite 数据。", comment: "App tool database category summary")
        case .feedback:
            return NSLocalizedString("由模型整理并提交问题或建议工单。", comment: "App tool feedback category summary")
        }
    }

    public var detailDescription: String {
        switch self {
        case .interaction:
            return NSLocalizedString("基础交互类适合让 AI 把内容先放进输入框，或用回显工具确认拓展工具链路是否正常。", comment: "App tool interaction category detail")
        case .memory:
            return NSLocalizedString("记忆操作类用于维护已经写入的长期记忆，包含分页查看、关键词筛选、内容编辑和归档恢复。", comment: "App tool memory category detail")
        case .file:
            return NSLocalizedString("文件操作类只能访问应用沙盒 Documents 目录，包含读取、搜索、写入、移动、复制、删除、差异查看和撤销最近修改。", comment: "App tool file category detail")
        case .database:
            return NSLocalizedString("数据库操作类面向聊天、配置与记忆数据库，查询工具只读，写入工具仍受审批策略和 SQL 限制保护。", comment: "App tool database category detail")
        case .feedback:
            return NSLocalizedString("反馈工单类用于把对话里的问题、复现步骤和建议整理为反馈记录。", comment: "App tool feedback category detail")
        }
    }
}

public struct AppToolCatalogCategoryState: Identifiable, Equatable, Sendable {
    public let category: AppToolCatalogCategory
    public let tools: [AppToolCatalogItem]
    public let configuredEnabledCount: Int
    public let availableCount: Int

    public var id: AppToolCatalogCategory { category }
    public var totalCount: Int { tools.count }

    public init(
        category: AppToolCatalogCategory,
        tools: [AppToolCatalogItem],
        configuredEnabledCount: Int,
        availableCount: Int
    ) {
        self.category = category
        self.tools = tools
        self.configuredEnabledCount = configuredEnabledCount
        self.availableCount = availableCount
    }
}

public enum ToolCatalogSupport {
    public static func builtInToolStates(
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool,
        memoryTopK: Int,
        enableWidgetTool: Bool,
        enableAskUserInputTool: Bool,
        enableGetSystemTimeTool: Bool,
        isIsolatedSession: Bool
    ) -> [ToolCatalogBuiltInToolState] {
        let memoryWriteConfiguredEnabled = enableMemory && enableMemoryWrite
        let memoryWriteAvailable = memoryWriteConfiguredEnabled && !isIsolatedSession
        let memoryWriteReason: ToolCatalogBuiltInToolStatusReason
        if memoryWriteConfiguredEnabled && isIsolatedSession {
            memoryWriteReason = .isolatedByWorldbook
        } else if !enableMemory {
            memoryWriteReason = .memoryDisabled
        } else if !enableMemoryWrite {
            memoryWriteReason = .memoryWriteDisabled
        } else {
            memoryWriteReason = .enabled
        }

        let resolvedTopK = max(0, memoryTopK)
        let memorySearchConfiguredEnabled = enableMemory && enableMemoryActiveRetrieval && resolvedTopK > 0
        let memorySearchAvailable = memorySearchConfiguredEnabled && !isIsolatedSession
        let memorySearchReason: ToolCatalogBuiltInToolStatusReason
        if memorySearchConfiguredEnabled && isIsolatedSession {
            memorySearchReason = .isolatedByWorldbook
        } else if !enableMemory {
            memorySearchReason = .memoryDisabled
        } else if !enableMemoryActiveRetrieval {
            memorySearchReason = .activeRetrievalDisabled
        } else if resolvedTopK <= 0 {
            memorySearchReason = .zeroTopK
        } else {
            memorySearchReason = .enabled
        }

        let widgetReason: ToolCatalogBuiltInToolStatusReason = enableWidgetTool ? .enabled : .widgetDisabled
        let askUserInputReason: ToolCatalogBuiltInToolStatusReason = enableAskUserInputTool ? .enabled : .askUserInputDisabled
        let getSystemTimeReason: ToolCatalogBuiltInToolStatusReason = enableGetSystemTimeTool ? .enabled : .getSystemTimeDisabled

        return [
            ToolCatalogBuiltInToolState(
                kind: .memoryWrite,
                isConfiguredEnabled: memoryWriteConfiguredEnabled,
                isAvailableInCurrentSession: memoryWriteAvailable,
                statusReason: memoryWriteReason
            ),
            ToolCatalogBuiltInToolState(
                kind: .memorySearch,
                isConfiguredEnabled: memorySearchConfiguredEnabled,
                isAvailableInCurrentSession: memorySearchAvailable,
                statusReason: memorySearchReason,
                memoryTopK: resolvedTopK
            ),
            ToolCatalogBuiltInToolState(
                kind: .widgetCard,
                isConfiguredEnabled: enableWidgetTool,
                isAvailableInCurrentSession: enableWidgetTool,
                statusReason: widgetReason
            ),
            ToolCatalogBuiltInToolState(
                kind: .askUserInput,
                isConfiguredEnabled: enableAskUserInputTool,
                isAvailableInCurrentSession: enableAskUserInputTool,
                statusReason: askUserInputReason
            ),
            ToolCatalogBuiltInToolState(
                kind: .getSystemTime,
                isConfiguredEnabled: enableGetSystemTimeTool,
                isAvailableInCurrentSession: enableGetSystemTimeTool,
                statusReason: getSystemTimeReason
            )
        ]
    }

    public static func configuredEnabledCount(for states: [ToolCatalogBuiltInToolState]) -> Int {
        states.filter(\.isConfiguredEnabled).count
    }

    public static func availableCount(for states: [ToolCatalogBuiltInToolState]) -> Int {
        states.filter(\.isAvailableInCurrentSession).count
    }

    public static func appToolCategory(for kind: AppToolKind) -> AppToolCatalogCategory {
        switch kind {
        case .echoText, .fillUserInput:
            return .interaction
        case .editMemory, .listMemories:
            return .memory
        case .listSandboxDirectory, .readSandboxFile, .writeSandboxFile, .searchSandboxFiles,
             .readSandboxFileChunk, .moveSandboxItem, .copySandboxItem, .createSandboxDirectory,
             .batchEditSandboxFile, .undoSandboxMutation, .diffSandboxFile, .editSandboxFile,
             .deleteSandboxItem:
            return .file
        case .listSQLiteTables, .querySQLite, .mutateSQLite:
            return .database
        case .submitFeedbackTicket:
            return .feedback
        case .showWidget, .askUserInput, .getSystemTime:
            return .interaction
        }
    }

    public static func appToolCategoryStates(
        tools: [AppToolCatalogItem],
        chatToolsEnabled: Bool,
        isIsolatedSession: Bool,
        approvalPolicy: (AppToolKind) -> AppToolApprovalPolicy
    ) -> [AppToolCatalogCategoryState] {
        AppToolCatalogCategory.allCases.compactMap { category in
            let categoryTools = tools.filter { appToolCategory(for: $0.kind) == category }
            guard !categoryTools.isEmpty else { return nil }

            let configuredEnabledCount = categoryTools.filter(\.isEnabled).count
            let availableCount: Int
            if chatToolsEnabled && !isIsolatedSession {
                availableCount = categoryTools.filter { item in
                    item.isEnabled && approvalPolicy(item.kind) != .alwaysDeny
                }.count
            } else {
                availableCount = 0
            }

            return AppToolCatalogCategoryState(
                category: category,
                tools: categoryTools,
                configuredEnabledCount: configuredEnabledCount,
                availableCount: availableCount
            )
        }
    }

    public static func mcpCatalogTools(
        servers: [MCPServerConfiguration],
        statuses: [UUID: MCPServerStatus]
    ) -> [MCPAvailableTool] {
        servers
            .filter(\.isSelectedForChat)
            .flatMap { server in
                let tools = statuses[server.id]?.tools ?? []
                return tools.enumerated().map { index, tool in
                    MCPAvailableTool(
                        server: server,
                        tool: tool,
                        internalName: "mcp://catalog/\(server.id.uuidString)/\(tool.toolId)/\(index)"
                    )
                }
            }
    }

    public static func sortedMCPCatalogTools(_ tools: [MCPAvailableTool]) -> [MCPAvailableTool] {
        tools.sorted {
            if $0.server.displayName == $1.server.displayName {
                return $0.tool.toolId.localizedCaseInsensitiveCompare($1.tool.toolId) == .orderedAscending
            }
            return $0.server.displayName.localizedCaseInsensitiveCompare($1.server.displayName) == .orderedAscending
        }
    }

    public static func schemaSummary(for schema: JSONValue?, fieldLimit: Int = 4) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }

        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }

        var segments: [String] = ["type=\(typeLabel)"]

        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            let fields = properties.keys.sorted().prefix(max(1, fieldLimit))
            segments.append("fields=\(fields.joined(separator: ", "))")
        }

        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item {
                    return key
                }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }

        return segments.joined(separator: " · ")
    }
}
