// ============================================================================
// MCPServerConfigurationTransferService.swift
// ============================================================================
// ETOS LLM Studio
//
// 读取和生成 Claude Code 等客户端常见的 mcpServers JSON。数据库仍是唯一
// 事实源；本服务只在用户或 Agent 明确操作时转换配置。
// ============================================================================

import Foundation

public struct MCPServerConfigurationImportResult: Sendable {
    public let servers: [MCPServerConfiguration]
    public let skippedNames: [String]
    public let sensitiveServerNames: [String]

    public init(
        servers: [MCPServerConfiguration],
        skippedNames: [String],
        sensitiveServerNames: [String]
    ) {
        self.servers = servers
        self.skippedNames = skippedNames
        self.sensitiveServerNames = sensitiveServerNames
    }
}

public enum MCPServerConfigurationTransferError: LocalizedError {
    case documentTooLarge
    case invalidRoot
    case noSupportedServer
    case invalidServer(name: String)

    public var errorDescription: String? {
        switch self {
        case .documentTooLarge:
            return NSLocalizedString("MCP 配置文件超过 2 MB，已拒绝导入。", comment: "MCP configuration import size error")
        case .invalidRoot:
            return NSLocalizedString("MCP JSON 必须包含 mcpServers 对象。", comment: "MCP configuration invalid root error")
        case .noSupportedServer:
            return NSLocalizedString("配置中没有可导入的 HTTP、SSE 或 stdio MCP Server。", comment: "MCP configuration no supported server error")
        case .invalidServer(let name):
            return String(
                format: NSLocalizedString("MCP Server“%@”的配置无效。", comment: "MCP configuration invalid server error"),
                name
            )
        }
    }
}

public enum MCPServerConfigurationTransferService {
    public static let maximumImportBytes = 2 * 1_024 * 1_024

    public static func importConfigurations(from data: Data) throws -> MCPServerConfigurationImportResult {
        guard data.count <= maximumImportBytes else {
            throw MCPServerConfigurationTransferError.documentTooLarge
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw MCPServerConfigurationTransferError.invalidRoot
        }
        let rawServers: [String: Any]
        if let nested = root["mcpServers"] as? [String: Any] {
            rawServers = nested
        } else if root.values.allSatisfy({ $0 is [String: Any] }) {
            rawServers = root
        } else {
            throw MCPServerConfigurationTransferError.invalidRoot
        }

        var servers: [MCPServerConfiguration] = []
        var skipped: [String] = []
        var sensitiveNames: [String] = []
        for name in rawServers.keys.sorted() {
            guard let raw = rawServers[name] as? [String: Any] else {
                skipped.append(name)
                continue
            }
            do {
                servers.append(try configuration(name: name, raw: raw))
                if containsSensitiveValue(raw) { sensitiveNames.append(name) }
            } catch {
                skipped.append(name)
            }
        }
        guard !servers.isEmpty else {
            throw MCPServerConfigurationTransferError.noSupportedServer
        }
        return MCPServerConfigurationImportResult(
            servers: servers,
            skippedNames: skipped,
            sensitiveServerNames: sensitiveNames
        )
    }

    public static func exportConfigurations(
        _ servers: [MCPServerConfiguration],
        includeSecrets: Bool
    ) throws -> Data {
        var exported: [String: Any] = [:]
        var usedNames = Set<String>()
        for server in servers {
            guard let value = exportedConfiguration(server, includeSecrets: includeSecrets) else {
                continue
            }
            let baseName = normalizedExportName(server.displayName, fallback: server.id.uuidString)
            var name = baseName
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(baseName)-\(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            exported[name] = value
        }
        return try JSONSerialization.data(
            withJSONObject: ["mcpServers": exported],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])
    }

    /// 常见 JSON 可以携带字面 env，但 ETOS 的 MCP Store 只保存 GRDB 变量 ID。
    /// 此转换只在用户最终保存配置时调用，导入预览阶段不会提前写数据库。
    static func materializeEnvironmentReferences(
        in server: MCPServerConfiguration
    ) -> MCPServerConfiguration? {
        guard case .localStdio(var configuration) = server.transport,
              !configuration.environment.isEmpty else {
            return server
        }
        var existing = Persistence.loadLocalLinuxEnvironmentVariables()
        var referencedIDs = Set(configuration.environmentVariableIDs)
        for name in configuration.environment.keys.sorted() {
            guard LocalLinuxProcessEnvironmentProvider.isValidName(name),
                  let value = configuration.environment[name] else {
                return nil
            }
            if let matching = existing.first(where: { $0.name == name && $0.value == value }) {
                referencedIDs.insert(matching.id)
                continue
            }
            let variable = LocalLinuxEnvironmentVariable(
                name: name,
                value: value,
                note: String(
                    format: NSLocalizedString("由 MCP“%@”导入", comment: "Imported MCP environment variable note"),
                    server.displayName
                )
            )
            guard Persistence.saveLocalLinuxEnvironmentVariable(variable) else { return nil }
            existing.append(variable)
            referencedIDs.insert(variable.id)
        }
        configuration.environment = [:]
        configuration.environmentVariableIDs = referencedIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        var normalized = server
        normalized.transport = .localStdio(configuration: configuration)
        return normalized
    }

    private static func configuration(name: String, raw: [String: Any]) throws -> MCPServerConfiguration {
        let type = (raw["type"] as? String ?? raw["transport"] as? String ?? "")
            .lowercased()
        if let command = nonEmptyString(raw["command"]) {
            let arguments = raw["args"] as? [String] ?? raw["arguments"] as? [String] ?? []
            let environment = stringDictionary(raw["env"] ?? raw["environment"])
            let cwd = nonEmptyString(raw["cwd"] ?? raw["workingDirectory"]) ?? "/home/etos"
            let launchPolicy = MCPLocalStdioLaunchPolicy(
                rawValue: nonEmptyString(raw["launchPolicy"]) ?? "on_demand"
            ) ?? .onDemand
            let idlePolicy = MCPLocalStdioIdlePolicy(
                rawValue: nonEmptyString(raw["idlePolicy"]) ?? "five_minutes"
            ) ?? .fiveMinutes
            let workspaceID = nonEmptyString(raw["workspaceID"]).flatMap(UUID.init(uuidString:))
            let mountIDs = (raw["mountIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            let startupTimeout = (raw["startupTimeout"] as? NSNumber)?.doubleValue ?? 30
            return MCPServerConfiguration(
                displayName: name,
                transport: .localStdio(
                    configuration: MCPLocalStdioConfiguration(
                        command: command,
                        arguments: arguments,
                        environment: environment,
                        inheritLocalLinuxEnvironment: raw["inheritLocalLinuxEnvironment"] as? Bool ?? true,
                        workingDirectory: cwd,
                        workspaceID: workspaceID,
                        mountIDs: mountIDs,
                        startupTimeoutSeconds: max(0, startupTimeout),
                        launchPolicy: launchPolicy,
                        idlePolicy: idlePolicy
                    )
                )
            )
        }

        guard let urlText = nonEmptyString(raw["url"] ?? raw["endpoint"]),
              let url = URL(string: urlText),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MCPServerConfigurationTransferError.invalidServer(name: name)
        }
        let headers = stringDictionary(raw["headers"] ?? raw["additionalHeaders"])
        if type == "sse" || type == "http+sse" {
            let messageURL = nonEmptyString(raw["messageUrl"] ?? raw["messageEndpoint"])
                .flatMap(URL.init(string:))
                ?? MCPServerConfiguration.inferMessageEndpoint(fromSSE: url)
            return MCPServerConfiguration(
                displayName: name,
                transport: .httpSSE(
                    messageEndpoint: messageURL,
                    sseEndpoint: url,
                    apiKey: nil,
                    additionalHeaders: headers
                )
            )
        }
        return MCPServerConfiguration(
            displayName: name,
            transport: .http(endpoint: url, apiKey: nil, additionalHeaders: headers)
        )
    }

    private static func exportedConfiguration(
        _ server: MCPServerConfiguration,
        includeSecrets: Bool
    ) -> [String: Any]? {
        switch server.transport {
        case .localStdio(let configuration):
            var result: [String: Any] = [
                "type": "stdio",
                "command": configuration.command,
                "args": configuration.arguments,
                "cwd": configuration.workingDirectory,
                "launchPolicy": configuration.launchPolicy.rawValue,
                "idlePolicy": configuration.idlePolicy.rawValue,
                "startupTimeout": configuration.startupTimeoutSeconds,
                "inheritLocalLinuxEnvironment": configuration.inheritLocalLinuxEnvironment
            ]
            if let workspaceID = configuration.workspaceID {
                result["workspaceID"] = workspaceID.uuidString
            }
            if !configuration.mountIDs.isEmpty {
                result["mountIDs"] = configuration.mountIDs.map(\.uuidString)
            }
            var referencedEnvironment = configuration.environment
            let referencedIDs = Set(configuration.environmentVariableIDs)
            for variable in Persistence.loadLocalLinuxEnvironmentVariables()
            where referencedIDs.contains(variable.id) {
                referencedEnvironment[variable.name] = variable.value
            }
            let environment = filteredSecrets(referencedEnvironment, includeSecrets: includeSecrets)
            if !environment.isEmpty { result["env"] = environment }
            return result
        case .http(let endpoint, let apiKey, let headers):
            var exportedHeaders = filteredSecrets(headers, includeSecrets: includeSecrets)
            if includeSecrets, let apiKey, !apiKey.isEmpty,
               !exportedHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                exportedHeaders["Authorization"] = "Bearer \(apiKey)"
            }
            var result: [String: Any] = ["type": "http", "url": endpoint.absoluteString]
            if !exportedHeaders.isEmpty { result["headers"] = exportedHeaders }
            return result
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let headers):
            var exportedHeaders = filteredSecrets(headers, includeSecrets: includeSecrets)
            if includeSecrets, let apiKey, !apiKey.isEmpty,
               !exportedHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                exportedHeaders["Authorization"] = "Bearer \(apiKey)"
            }
            var result: [String: Any] = [
                "type": "sse",
                "url": sseEndpoint.absoluteString,
                "messageUrl": messageEndpoint.absoluteString
            ]
            if !exportedHeaders.isEmpty { result["headers"] = exportedHeaders }
            return result
        case .oauth, .builtInSearch, .builtInAppTool, .builtInPersonalData:
            return nil
        }
    }

    private static func filteredSecrets(
        _ values: [String: String],
        includeSecrets: Bool
    ) -> [String: String] {
        guard !includeSecrets else { return values }
        return values.filter { !isSensitiveKey($0.key) }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return ["token", "key", "secret", "auth", "password", "passwd", "cookie"]
            .contains { normalized.contains($0) }
    }

    private static func containsSensitiveValue(_ value: Any) -> Bool {
        guard let dictionary = value as? [String: Any] else { return false }
        for (key, child) in dictionary {
            if isSensitiveKey(key), child is String { return true }
            if let nested = child as? [String: Any], containsSensitiveValue(nested) {
                return true
            }
        }
        return false
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, pair in
            if let value = pair.value as? String, value != "***" {
                result[pair.key] = value
            }
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedExportName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

public enum MCPServerManagementTool {
    public static let name = "manage_mcp_servers"

    public static let definition = MCPToolDescription(
        toolId: name,
        description: NSLocalizedString(
            "查看、导入或删除 MCP Server 配置。导入接受常见 mcpServers JSON；导出永远移除敏感环境变量和鉴权字段。不会自动安装本地 Server 依赖。",
            comment: "Manage MCP servers tool description"
        ),
        inputSchema: .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "action": .dictionary([
                    "type": .string("string"),
                    "enum": .array([.string("list"), .string("import_json"), .string("export_json"), .string("delete")])
                ]),
                "json": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("import_json 使用的 mcpServers JSON。", comment: "Manage MCP servers JSON parameter"))
                ]),
                "server_id": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("delete 使用的 MCP Server UUID。", comment: "Manage MCP servers ID parameter"))
                ])
            ]),
            "required": .array([.string("action")])
        ]),
        examples: nil
    )

    @MainActor
    public static func execute(argumentsJSON: String) throws -> String {
        let data = Data(argumentsJSON.utf8)
        let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let action = arguments["action"] as? String else {
            throw MCPServerConfigurationTransferError.invalidRoot
        }
        switch action {
        case "list":
            let summaries = MCPManager.shared.servers.map { server in
                [
                    "id": server.id.uuidString,
                    "name": server.displayName,
                    "endpoint": server.humanReadableEndpoint,
                    "selected": server.isSelectedForChat
                ] as [String: Any]
            }
            return try jsonString(["servers": summaries])
        case "import_json":
            guard let text = arguments["json"] as? String else {
                throw MCPServerConfigurationTransferError.invalidRoot
            }
            let result = try MCPServerConfigurationTransferService.importConfigurations(
                from: Data(text.utf8)
            )
            result.servers.forEach { MCPManager.shared.save(server: $0) }
            return try jsonString([
                "imported": result.servers.map(\.displayName),
                "skipped": result.skippedNames
            ])
        case "export_json":
            let exported = try MCPServerConfigurationTransferService.exportConfigurations(
                MCPManager.shared.servers,
                includeSecrets: false
            )
            return String(decoding: exported, as: UTF8.self)
        case "delete":
            guard let idText = arguments["server_id"] as? String,
                  let id = UUID(uuidString: idText),
                  let server = MCPManager.shared.servers.first(where: { $0.id == id }) else {
                throw MCPServerConfigurationTransferError.invalidRoot
            }
            MCPManager.shared.delete(server: server)
            return try jsonString(["deleted": server.displayName, "id": server.id.uuidString])
        default:
            throw MCPServerConfigurationTransferError.invalidRoot
        }
    }

    private static func jsonString(_ value: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            as: UTF8.self
        )
    }
}
