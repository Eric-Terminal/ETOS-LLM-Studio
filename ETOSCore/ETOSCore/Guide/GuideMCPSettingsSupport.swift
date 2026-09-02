// ============================================================================
// GuideMCPSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP 向导只接收结构化提案；已有认证值不会进入页面快照。
// ============================================================================

import Foundation

public struct GuideMCPServerApplication: Sendable {
    public let server: MCPServerConfiguration
    public let execution: GuideActionExecution

    public init(server: MCPServerConfiguration, execution: GuideActionExecution) {
        self.server = server
        self.execution = execution
    }
}

public enum GuideMCPServerSettingsSupport {
    private static let restoreToolName = "restore_mcp_server_after_guide_change"
    private static let allowedKeys: Set<String> = [
        "display_name",
        "notes",
        "selected_for_chat",
        "configuration"
    ]

    public static func snapshot(
        server: MCPServerConfiguration,
        status: MCPServerStatus
    ) -> GuidePageSnapshot {
        let tools = status.tools.map { tool in
            JSONValue.dictionary([
                "id": .string(tool.toolId),
                "description": .string(tool.description ?? ""),
                "enabled": .bool(server.isToolEnabled(tool.toolId)),
                "approval_policy": .string(server.approvalPolicy(for: tool.toolId).rawValue),
                "approval_locked": .bool(MCPNativeCapabilityPolicy.requiresPerCallApproval(tool.toolId))
            ])
        }
        return GuidePageSnapshot(fields: [
            "server_id": GuideSnapshotField(
                label: NSLocalizedString("服务器 ID", comment: "MCP 向导快照字段"),
                value: .string(server.id.uuidString),
                access: .readOnly
            ),
            "display_name": GuideSnapshotField(
                label: NSLocalizedString("显示名称", comment: "MCP 向导快照字段"),
                value: .string(server.displayName)
            ),
            "notes": GuideSnapshotField(
                label: NSLocalizedString("备注", comment: "MCP 向导快照字段"),
                value: .string(server.notes ?? "")
            ),
            "selected_for_chat": GuideSnapshotField(
                label: NSLocalizedString("用于聊天", comment: "MCP 向导快照字段"),
                value: .bool(server.isSelectedForChat)
            ),
            "configuration": GuideSnapshotField(
                label: NSLocalizedString("连接配置", comment: "MCP 向导快照字段"),
                value: safeConfigurationValue(server)
            ),
            "connection_state": GuideSnapshotField(
                label: NSLocalizedString("连接状态", comment: "MCP 向导快照字段"),
                value: .string(connectionStateValue(status.connectionState)),
                access: .readOnly
            ),
            "server_capabilities": GuideSnapshotField(
                label: NSLocalizedString("服务器能力", comment: "MCP 向导快照字段"),
                value: .array((status.info?.capabilities?.keys.sorted() ?? []).map(JSONValue.string)),
                access: .readOnly
            ),
            "tools": GuideSnapshotField(
                label: NSLocalizedString("已公布工具", comment: "MCP 向导快照字段"),
                value: .array(tools),
                access: .readOnly
            ),
            "resource_count": GuideSnapshotField(
                label: NSLocalizedString("资源数量", comment: "MCP 向导快照字段"),
                value: .int(status.resources.count),
                access: .readOnly
            )
        ])
    }

    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID,
        server: MCPServerConfiguration
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.updateMCPServer.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        let updated = try applying(arguments, to: server)
        guard updated != server else { throw GuideError.invalidToolArguments }
        let containsSensitiveValues = GuideSecretRedactor.containsSensitiveField(.dictionary(arguments))
        return GuideActionProposal(
            pageID: pageID,
            toolCallID: call.id,
            toolName: call.toolName,
            summary: containsSensitiveValues
                ? NSLocalizedString("修改 MCP 服务器（包含新的认证值，请仔细确认）", comment: "MCP 向导服务器提案摘要")
                : NSLocalizedString("修改 MCP 服务器", comment: "MCP 向导服务器提案摘要"),
            mutations: [GuideSettingMutation(
                path: "server",
                label: NSLocalizedString("MCP 服务器配置", comment: "MCP 向导服务器修改字段"),
                oldValue: safeServerValue(server),
                newValue: safeServerValue(updated),
                isSensitive: containsSensitiveValues
            )],
            arguments: arguments
        )
    }

    public static func apply(
        _ proposal: GuideActionProposal,
        to server: MCPServerConfiguration
    ) throws -> GuideMCPServerApplication {
        let updated: MCPServerConfiguration
        let undo: GuideActionProposal?
        if proposal.toolName == restoreToolName {
            try GuideToolArguments.requireOnlyKeys(["server"], in: proposal.arguments)
            guard let value = proposal.arguments["server"] else { throw GuideError.invalidToolArguments }
            updated = try decodeServer(value)
            undo = nil
        } else {
            guard proposal.toolName == GuideToolCatalog.updateMCPServer.name else {
                throw GuideError.unsupportedTool(proposal.toolName)
            }
            updated = try applying(proposal.arguments, to: server)
            undo = GuideActionProposal(
                pageID: proposal.pageID,
                toolCallID: "undo-\(proposal.toolCallID)",
                toolName: restoreToolName,
                summary: NSLocalizedString("撤销 MCP 服务器修改", comment: "MCP 向导服务器撤销摘要"),
                mutations: [],
                arguments: ["server": try encodeServer(server)]
            )
        }
        return GuideMCPServerApplication(
            server: updated,
            execution: GuideActionExecution(
                message: String(
                    format: NSLocalizedString("已更新 MCP 服务器“%@”。", comment: "MCP 向导服务器执行结果"),
                    updated.displayName
                ),
                undoProposal: undo
            )
        )
    }

    private static func applying(
        _ arguments: [String: JSONValue],
        to server: MCPServerConfiguration
    ) throws -> MCPServerConfiguration {
        try GuideToolArguments.requireOnlyKeys(allowedKeys, in: arguments)
        var updated = server
        if let displayName = try GuideToolArguments.optionalString("display_name", in: arguments) {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw GuideError.invalidToolArguments }
            updated.displayName = trimmed
        }
        if let notes = try GuideToolArguments.optionalString("notes", in: arguments) {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.notes = trimmed.isEmpty ? nil : trimmed
        }
        if let selected = try GuideToolArguments.optionalBool("selected_for_chat", in: arguments) {
            updated.isSelectedForChat = selected
        }
        if let configurationValue = arguments["configuration"] {
            guard case .dictionary(let configuration) = configurationValue,
                  !isBuiltIn(server.transport) else {
                throw GuideError.invalidToolArguments
            }
            updated.transport = try decodedTransport(
                configuration,
                displayName: updated.displayName,
                existing: server.transport
            )
        }
        return updated
    }

    private static func decodedTransport(
        _ configuration: [String: JSONValue],
        displayName: String,
        existing: MCPServerConfiguration.Transport
    ) throws -> MCPServerConfiguration.Transport {
        if string(configuration["type"])?.lowercased() == "oauth" {
            return try decodedOAuthTransport(configuration, existing: existing)
        }
        let root = JSONValue.dictionary([
            "mcpServers": .dictionary([displayName: .dictionary(configuration)])
        ])
        let data = try JSONSerialization.data(withJSONObject: root.toAny(), options: [.sortedKeys])
        let result = try MCPServerConfigurationTransferService.importConfigurations(from: data)
        guard result.servers.count == 1, result.skippedNames.isEmpty else {
            throw GuideError.invalidToolArguments
        }
        return preservingHiddenValues(in: result.servers[0].transport, from: existing)
    }

    private static func decodedOAuthTransport(
        _ configuration: [String: JSONValue],
        existing: MCPServerConfiguration.Transport
    ) throws -> MCPServerConfiguration.Transport {
        let old: (
            clientSecret: String?,
            authorizationCode: String?,
            redirectURI: String?,
            codeVerifier: String?
        )
        if case .oauth(_, _, _, let clientSecret, _, _, let authorizationCode, let redirectURI, let codeVerifier) = existing {
            old = (clientSecret, authorizationCode, redirectURI, codeVerifier)
        } else {
            old = (nil, nil, nil, nil)
        }
        guard let endpoint = httpURL(configuration["url"] ?? configuration["endpoint"]),
              let tokenEndpoint = httpURL(configuration["tokenEndpoint"] ?? configuration["token_endpoint"]),
              let clientID = nonEmptyString(configuration["clientID"] ?? configuration["client_id"]) else {
            throw GuideError.invalidToolArguments
        }
        let grantRaw = string(configuration["grantType"] ?? configuration["grant_type"])
            ?? MCPOAuthGrantType.clientCredentials.rawValue
        guard let grantType = MCPOAuthGrantType(rawValue: grantRaw) else {
            throw GuideError.invalidToolArguments
        }
        return .oauth(
            endpoint: endpoint,
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            clientSecret: optionalString(configuration["clientSecret"] ?? configuration["client_secret"]) ?? old.clientSecret,
            scope: optionalString(configuration["scope"]),
            grantType: grantType,
            authorizationCode: optionalString(configuration["authorizationCode"] ?? configuration["authorization_code"]) ?? old.authorizationCode,
            redirectURI: optionalString(configuration["redirectURI"] ?? configuration["redirect_uri"]) ?? old.redirectURI,
            codeVerifier: optionalString(configuration["codeVerifier"] ?? configuration["code_verifier"]) ?? old.codeVerifier
        )
    }

    private static func preservingHiddenValues(
        in transport: MCPServerConfiguration.Transport,
        from existing: MCPServerConfiguration.Transport
    ) -> MCPServerConfiguration.Transport {
        switch (transport, existing) {
        case let (.http(endpoint, apiKey, headers), .http(_, oldAPIKey, oldHeaders)):
            return .http(
                endpoint: endpoint,
                apiKey: apiKey ?? oldAPIKey,
                additionalHeaders: mergingHiddenHeaders(headers, old: oldHeaders)
            )
        case let (.httpSSE(messageEndpoint, sseEndpoint, apiKey, headers), .httpSSE(_, _, oldAPIKey, oldHeaders)):
            return .httpSSE(
                messageEndpoint: messageEndpoint,
                sseEndpoint: sseEndpoint,
                apiKey: apiKey ?? oldAPIKey,
                additionalHeaders: mergingHiddenHeaders(headers, old: oldHeaders)
            )
        case let (.localStdio(configuration), .localStdio(oldConfiguration)):
            var merged = configuration
            merged.environmentVariableIDs = Array(
                Set(configuration.environmentVariableIDs).union(oldConfiguration.environmentVariableIDs)
            ).sorted { $0.uuidString < $1.uuidString }
            return .localStdio(configuration: merged)
        default:
            return transport
        }
    }

    private static func mergingHiddenHeaders(
        _ headers: [String: String],
        old: [String: String]
    ) -> [String: String] {
        var merged = headers
        for (key, value) in old where isSensitiveHeader(key) {
            let alreadyPresent = merged.keys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
            if !alreadyPresent { merged[key] = value }
        }
        return merged
    }

    private static func safeServerValue(_ server: MCPServerConfiguration) -> JSONValue {
        .dictionary([
            "id": .string(server.id.uuidString),
            "display_name": .string(server.displayName),
            "notes": .string(server.notes ?? ""),
            "selected_for_chat": .bool(server.isSelectedForChat),
            "configuration": safeConfigurationValue(server)
        ])
    }

    private static func safeConfigurationValue(_ server: MCPServerConfiguration) -> JSONValue {
        switch server.transport {
        case .http(let endpoint, let apiKey, let headers):
            return .dictionary([
                "type": .string("http"),
                "url": .string(endpoint.absoluteString),
                "headers": GuideSecretRedactor.redact(.dictionary(headers.mapValues(JSONValue.string))),
                "api_key_configured": .bool(apiKey?.isEmpty == false)
            ])
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let headers):
            return .dictionary([
                "type": .string("sse"),
                "url": .string(sseEndpoint.absoluteString),
                "message_url": .string(messageEndpoint.absoluteString),
                "headers": GuideSecretRedactor.redact(.dictionary(headers.mapValues(JSONValue.string))),
                "api_key_configured": .bool(apiKey?.isEmpty == false)
            ])
        case .localStdio(let configuration):
            return .dictionary([
                "type": .string("stdio"),
                "command": .string(configuration.command),
                "args": .array(configuration.arguments.map(JSONValue.string)),
                "cwd": .string(configuration.workingDirectory),
                "environment_variable_count": .int(configuration.environmentVariableIDs.count + configuration.environment.count),
                "inherit_local_linux_environment": .bool(configuration.inheritLocalLinuxEnvironment),
                "workspace_id": .string(configuration.workspaceID?.uuidString ?? ""),
                "mount_ids": .array(configuration.mountIDs.map { .string($0.uuidString) }),
                "startup_timeout": .double(configuration.startupTimeoutSeconds),
                "launch_policy": .string(configuration.launchPolicy.rawValue),
                "idle_policy": .string(configuration.idlePolicy.rawValue)
            ])
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            return .dictionary([
                "type": .string("oauth"),
                "url": .string(endpoint.absoluteString),
                "token_endpoint": .string(tokenEndpoint.absoluteString),
                "client_id": .string(clientID),
                "client_secret_configured": .bool(clientSecret?.isEmpty == false),
                "scope": .string(scope ?? ""),
                "grant_type": .string(grantType.rawValue),
                "authorization_code_configured": .bool(authorizationCode?.isEmpty == false),
                "redirect_uri": .string(redirectURI ?? ""),
                "code_verifier_configured": .bool(codeVerifier?.isEmpty == false)
            ])
        case .builtInSearch:
            return .dictionary(["type": .string("built_in_search")])
        case .builtInAppTool(let category):
            return .dictionary([
                "type": .string("built_in_app_tool"),
                "category": .string(category.rawValue)
            ])
        case .builtInPersonalData:
            return .dictionary(["type": .string("built_in_personal_data")])
        }
    }

    private static func connectionStateValue(_ state: MCPManager.ConnectionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .reconnecting: return "reconnecting"
        case .ready: return "ready"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private static func isBuiltIn(_ transport: MCPServerConfiguration.Transport) -> Bool {
        switch transport {
        case .builtInSearch, .builtInAppTool, .builtInPersonalData: return true
        case .http, .httpSSE, .localStdio, .oauth: return false
        }
    }

    private static func isSensitiveHeader(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return ["token", "key", "secret", "auth", "password", "passwd", "cookie"]
            .contains { normalized.contains($0) }
    }

    private static func httpURL(_ value: JSONValue?) -> URL? {
        guard let text = nonEmptyString(value),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func encodeServer(_ server: MCPServerConfiguration) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(server))
    }

    private static func decodeServer(_ value: JSONValue) throws -> MCPServerConfiguration {
        let data = try JSONSerialization.data(withJSONObject: value.toAny(), options: [.sortedKeys])
        return try JSONDecoder().decode(MCPServerConfiguration.self, from: data)
    }
}

public struct GuideMCPToolApplication: Sendable {
    public let enabled: Bool
    public let approvalPolicy: MCPToolApprovalPolicy
    public let execution: GuideActionExecution

    public init(enabled: Bool, approvalPolicy: MCPToolApprovalPolicy, execution: GuideActionExecution) {
        self.enabled = enabled
        self.approvalPolicy = approvalPolicy
        self.execution = execution
    }
}

public enum GuideMCPToolSettingsSupport {
    private static let restoreToolName = "restore_mcp_tool_after_guide_change"
    private static let allowedKeys: Set<String> = ["enabled", "approval_policy"]

    public static func snapshot(
        server: MCPServerConfiguration,
        tool: MCPToolDescription
    ) -> GuidePageSnapshot {
        GuidePageSnapshot(fields: [
            "server_id": GuideSnapshotField(
                label: NSLocalizedString("服务器 ID", comment: "MCP 工具向导快照字段"),
                value: .string(server.id.uuidString),
                access: .readOnly
            ),
            "server_name": GuideSnapshotField(
                label: NSLocalizedString("服务器", comment: "MCP 工具向导快照字段"),
                value: .string(server.displayName),
                access: .readOnly
            ),
            "tool_id": GuideSnapshotField(
                label: NSLocalizedString("工具 ID", comment: "MCP 工具向导快照字段"),
                value: .string(tool.toolId),
                access: .readOnly
            ),
            "description": GuideSnapshotField(
                label: NSLocalizedString("工具描述", comment: "MCP 工具向导快照字段"),
                value: .string(tool.description ?? ""),
                access: .readOnly
            ),
            "input_schema": GuideSnapshotField(
                label: NSLocalizedString("输入 Schema", comment: "MCP 工具向导快照字段"),
                value: tool.inputSchema ?? .null,
                access: .readOnly
            ),
            "enabled": GuideSnapshotField(
                label: NSLocalizedString("启用", comment: "MCP 工具向导快照字段"),
                value: .bool(server.isToolEnabled(tool.toolId))
            ),
            "approval_policy": GuideSnapshotField(
                label: NSLocalizedString("审批策略", comment: "MCP 工具向导快照字段"),
                value: .string(server.approvalPolicy(for: tool.toolId).rawValue)
            ),
            "approval_locked": GuideSnapshotField(
                label: NSLocalizedString("审批策略固定", comment: "MCP 工具向导快照字段"),
                value: .bool(MCPNativeCapabilityPolicy.requiresPerCallApproval(tool.toolId)),
                access: .readOnly
            )
        ])
    }

    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID,
        server: MCPServerConfiguration,
        tool: MCPToolDescription
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.updateMCPTool.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        let resolved = try values(arguments, server: server, tool: tool)
        var mutations: [GuideSettingMutation] = []
        let oldEnabled = server.isToolEnabled(tool.toolId)
        let oldPolicy = server.approvalPolicy(for: tool.toolId)
        if resolved.enabled != oldEnabled {
            mutations.append(GuideSettingMutation(
                path: "enabled",
                label: NSLocalizedString("启用", comment: "MCP 工具向导修改字段"),
                oldValue: .bool(oldEnabled),
                newValue: .bool(resolved.enabled)
            ))
        }
        if resolved.approvalPolicy != oldPolicy {
            mutations.append(GuideSettingMutation(
                path: "approval_policy",
                label: NSLocalizedString("审批策略", comment: "MCP 工具向导修改字段"),
                oldValue: .string(oldPolicy.rawValue),
                newValue: .string(resolved.approvalPolicy.rawValue)
            ))
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: pageID,
            toolCallID: call.id,
            toolName: call.toolName,
            summary: String(
                format: NSLocalizedString("修改 MCP 工具“%@”", comment: "MCP 工具向导提案摘要"),
                tool.toolId
            ),
            mutations: mutations,
            arguments: arguments
        )
    }

    public static func apply(
        _ proposal: GuideActionProposal,
        server: MCPServerConfiguration,
        tool: MCPToolDescription
    ) throws -> GuideMCPToolApplication {
        let resolved: (enabled: Bool, approvalPolicy: MCPToolApprovalPolicy)
        let undo: GuideActionProposal?
        if proposal.toolName == restoreToolName {
            resolved = try values(proposal.arguments, server: server, tool: tool)
            undo = nil
        } else {
            guard proposal.toolName == GuideToolCatalog.updateMCPTool.name else {
                throw GuideError.unsupportedTool(proposal.toolName)
            }
            resolved = try values(proposal.arguments, server: server, tool: tool)
            undo = GuideActionProposal(
                pageID: proposal.pageID,
                toolCallID: "undo-\(proposal.toolCallID)",
                toolName: restoreToolName,
                summary: NSLocalizedString("撤销 MCP 工具设置修改", comment: "MCP 工具向导撤销摘要"),
                mutations: [],
                arguments: [
                    "enabled": .bool(server.isToolEnabled(tool.toolId)),
                    "approval_policy": .string(server.approvalPolicy(for: tool.toolId).rawValue)
                ]
            )
        }
        return GuideMCPToolApplication(
            enabled: resolved.enabled,
            approvalPolicy: resolved.approvalPolicy,
            execution: GuideActionExecution(
                message: String(
                    format: NSLocalizedString("已更新 MCP 工具“%@”。", comment: "MCP 工具向导执行结果"),
                    tool.toolId
                ),
                undoProposal: undo
            )
        )
    }

    private static func values(
        _ arguments: [String: JSONValue],
        server: MCPServerConfiguration,
        tool: MCPToolDescription
    ) throws -> (enabled: Bool, approvalPolicy: MCPToolApprovalPolicy) {
        try GuideToolArguments.requireOnlyKeys(allowedKeys, in: arguments)
        let enabled = try GuideToolArguments.optionalBool("enabled", in: arguments)
            ?? server.isToolEnabled(tool.toolId)
        let requestedPolicy: MCPToolApprovalPolicy
        if let raw = try GuideToolArguments.optionalString("approval_policy", in: arguments) {
            guard let policy = MCPToolApprovalPolicy(rawValue: raw) else {
                throw GuideError.invalidToolArguments
            }
            requestedPolicy = policy
        } else {
            requestedPolicy = server.approvalPolicy(for: tool.toolId)
        }
        let approvalPolicy = MCPNativeCapabilityPolicy.requiresPerCallApproval(tool.toolId)
            ? .askEveryTime
            : requestedPolicy
        return (enabled, approvalPolicy)
    }
}
