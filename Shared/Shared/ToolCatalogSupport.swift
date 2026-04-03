// ============================================================================
// ToolCatalogSupport.swift
// ============================================================================
// 统一工具中心所需的共享辅助逻辑。
// - 汇总内置工具状态
// - 生成工具参数 Schema 摘要
// ============================================================================

import Foundation

public enum ToolCatalogBuiltInToolKind: String, CaseIterable, Identifiable, Sendable {
    case memoryWrite
    case memorySearch

    public var id: String { rawValue }
}

public enum ToolCatalogBuiltInToolStatusReason: String, Equatable, Sendable {
    case enabled
    case memoryDisabled
    case memoryWriteDisabled
    case activeRetrievalDisabled
    case zeroTopK
    case isolatedByWorldbook
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

public enum ToolCatalogSupport {
    public static func builtInToolStates(
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool,
        memoryTopK: Int,
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
            )
        ]
    }

    public static func configuredEnabledCount(for states: [ToolCatalogBuiltInToolState]) -> Int {
        states.filter(\.isConfiguredEnabled).count
    }

    public static func availableCount(for states: [ToolCatalogBuiltInToolState]) -> Int {
        states.filter(\.isAvailableInCurrentSession).count
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
