// ============================================================================
// MCPManagerInteraction.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 MCP 管理器的调试调用、资源与提示词读取、
// 日志与缓存控制，以及聊天工具桥接接口。
// ============================================================================

import Foundation
import Combine

extension MCPManager {
    @discardableResult
    public func executeTool(
        on serverID: UUID,
        toolId: String,
        inputs: [String: JSONValue],
        options: MCPManagedToolCallOptions? = nil
    ) -> UUID {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试调用工具：%@", comment: "MCP governance debug tool call started"), toolId))
        let resolvedOptions = options ?? defaultManagedToolCallOptions(
            timeout: defaultToolCallTimeout,
            reason: NSLocalizedString("调试工具调用超时", comment: "MCP debug tool call timeout reason")
        )
        let callID = UUID()

        Task {
            do {
                let result = try await self.executeManagedToolCall(
                    callID: callID,
                    serverID: serverID,
                    toolId: toolId,
                    inputs: inputs,
                    options: resolvedOptions
                )
                self.lastOperationOutput = result.prettyPrinted()
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试工具调用成功：%@", comment: "MCP governance debug tool call succeeded"), toolId))
            } catch is CancellationError {
                self.lastOperationError = NSLocalizedString("工具调用已取消。", comment: "MCP tool call cancelled error")
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .warning, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试工具调用已取消：%@", comment: "MCP governance debug tool call cancelled"), toolId))
            } catch {
                self.lastOperationError = error.localizedDescription
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试工具调用失败：%@，错误=%@", comment: "MCP governance debug tool call failed"), toolId, error.localizedDescription))
            }
        }
        return callID
    }

    public func executeToolAsync(
        on serverID: UUID,
        toolId: String,
        inputs: [String: JSONValue],
        options: MCPManagedToolCallOptions
    ) async throws -> JSONValue {
        let callID = UUID()
        return try await executeManagedToolCall(
            callID: callID,
            serverID: serverID,
            toolId: toolId,
            inputs: inputs,
            options: options
        )
    }

    public func cancelToolCall(callID: UUID, reason: String = NSLocalizedString("用户取消调用", comment: "MCP user cancelled tool call reason")) {
        guard let task = trackedToolCallTasks[callID] else { return }
        task.cancel()
        if var call = activeToolCalls[callID] {
            call.state = .cancelling
            activeToolCalls[callID] = call
            appendGovernanceLog(
                level: .warning,
                category: .toolCall,
                serverID: call.serverID,
                message: String(format: NSLocalizedString("工具调用已请求取消：%@，原因=%@", comment: "MCP governance tool call cancel requested"), call.toolId, reason)
            )
        }
    }

    public func readResource(on serverID: UUID, resourceId: String, query: [String: JSONValue]?) {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试读取资源：%@", comment: "MCP governance debug resource read started"), resourceId))

        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                let result = try await client.readResource(resourceId: resourceId, query: query)
                self.lastOperationOutput = result.prettyPrinted()
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试资源读取成功：%@", comment: "MCP governance debug resource read succeeded"), resourceId))
            } catch {
                self.lastOperationError = error.localizedDescription
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试资源读取失败：%@，错误=%@", comment: "MCP governance debug resource read failed"), resourceId, error.localizedDescription))
            }
        }
    }

    public func getPrompt(on serverID: UUID, name: String, arguments: [String: String]?) {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试获取提示词：%@", comment: "MCP governance debug prompt get started"), name))

        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                let result = try await client.getPrompt(name: name, arguments: arguments)
                self.lastOperationOutput = self.formatPromptResult(result)
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试提示词获取成功：%@", comment: "MCP governance debug prompt get succeeded"), name))
            } catch {
                self.lastOperationError = error.localizedDescription
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: String(format: NSLocalizedString("调试提示词获取失败：%@，错误=%@", comment: "MCP governance debug prompt get failed"), name, error.localizedDescription))
            }
        }
    }

    public func getPromptFromChat(promptName: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        guard let routed = routedPrompts[promptName] else {
            throw MCPChatBridgeError.unknownPrompt
        }
        let client = try await ensureClientReady(serverID: routed.server.id, refreshMetadataIfCacheMissing: false)
        return try await client.getPrompt(name: routed.prompt.name, arguments: arguments)
    }

    func formatPromptResult(_ result: MCPGetPromptResult) -> String {
        var output = ""
        if let desc = result.description {
            output += String(format: NSLocalizedString("描述：%@", comment: "MCP prompt result description"), desc) + "\n\n"
        }
        output += NSLocalizedString("消息：", comment: "MCP prompt result messages header") + "\n"
        for (index, message) in result.messages.enumerated() {
            output += "[\(index + 1)] \(message.role):\n"
            switch message.content {
            case .text(let text):
                output += text
            case .image(let data, let mimeType):
                output += String(format: NSLocalizedString("[图片: %@, %d bytes]", comment: "MCP prompt result image placeholder"), mimeType, data.count)
            case .resource(let uri, let mimeType, let text):
                output += String(format: NSLocalizedString("[资源: %@", comment: "MCP prompt result resource placeholder prefix"), uri)
                if let mimeType { output += ", \(mimeType)" }
                if let text { output += "]\n\(text)" } else { output += "]" }
            }
            output += "\n\n"
        }
        return output
    }

    public func setLogLevel(on serverID: UUID, level: MCPLogLevel) {
        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                try await client.setLogLevel(level)
                self.updateStatus(for: serverID) {
                    $0.logLevel = level
                }
                self.appendGovernanceLog(level: .info, category: .lifecycle, serverID: serverID, message: String(format: NSLocalizedString("日志级别已更新为 %@。", comment: "MCP governance log level updated"), level.rawValue))
            } catch {
                self.lastOperationError = error.localizedDescription
                self.appendGovernanceLog(level: .error, category: .lifecycle, serverID: serverID, message: String(format: NSLocalizedString("更新日志级别失败：%@", comment: "MCP governance log level update failed"), error.localizedDescription))
            }
        }
    }

    public func clearLogEntries() {
        logEntries.removeAll()
    }

    public func clearGovernanceLogEntries() {
        governanceLogEntries.removeAll()
    }

    public func invalidateMetadataCache(for serverID: UUID, reason: String, refreshIfConnected: Bool = true) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        MCPServerStore.saveMetadata(nil, for: serverID)
        updateStatus(for: serverID) {
            $0.tools = []
            $0.resources = []
            $0.resourceTemplates = []
            $0.prompts = []
            $0.roots = []
            $0.metadataCachedAt = nil
        }
        appendGovernanceLog(level: .warning, category: .cache, serverID: serverID, message: String(format: NSLocalizedString("元数据缓存已失效：%@", comment: "MCP governance metadata cache invalidated"), reason))
        if refreshIfConnected, case .ready = status(for: server).connectionState {
            refreshMetadata(for: server)
        }
    }

    public func invalidateAllMetadataCaches(reason: String, refreshIfConnected: Bool = true) {
        let serverIDs = servers.map(\.id)
        for serverID in serverIDs {
            invalidateMetadataCache(for: serverID, reason: reason, refreshIfConnected: refreshIfConnected)
        }
    }

    public func setChatToolsEnabled(_ isEnabled: Bool) {
        guard chatToolsEnabled != isEnabled else { return }
        chatToolsEnabled = isEnabled
        AppConfigStore.persistSynchronously(.bool(isEnabled), for: .mcpChatToolsEnabled)
        let stateText = isEnabled
            ? NSLocalizedString("开启", comment: "MCP enabled state")
            : NSLocalizedString("关闭", comment: "MCP disabled state")
        appendGovernanceLog(level: .info, category: .routing, message: String(format: NSLocalizedString("MCP 聊天工具总开关已%@。", comment: "MCP governance chat tools switch changed"), stateText))
        if isEnabled {
            connectSelectedServersIfNeeded()
        } else {
            cancelAllAutoConnectRetries(resetAttempts: true)
            rebuildAggregates()
        }
    }

    public func reloadAppConfigBackedState() {
        let previousValue = chatToolsEnabled
        chatToolsEnabled = AppConfigStore.boolValue(
            for: .mcpChatToolsEnabled,
            legacyUserDefaultsKey: Self.chatToolsEnabledUserDefaultsKey,
            defaultValue: true
        )
        if chatToolsEnabled {
            if !previousValue {
                connectSelectedServersIfNeeded()
            }
        } else {
            cancelAllAutoConnectRetries(resetAttempts: true)
            rebuildAggregates()
        }
        objectWillChange.send()
    }

    public func chatToolsForLLM(
        includeConversationAgentTools: Bool = false,
        includeLocalLinuxTools: Bool = false,
        includeBrowserAgentTools: Bool = false,
        selectedServerIDs: Set<UUID>? = nil
    ) -> [InternalToolDefinition] {
        // 只有 Linux 能力由 Agent 模式额外开启。浏览器和会话协作属于普通 MCP
        // 聊天工具，必须继续服从 MCP 总开关。
        guard chatToolsEnabled || includeLocalLinuxTools else { return [] }
        let chatTools: [InternalToolDefinition] = tools.compactMap { available -> InternalToolDefinition? in
            if let selectedServerIDs,
               !selectedServerIDs.contains(available.server.id) {
                return nil
            }
            // 本地 stdio MCP 与 Linux 用户态共享进程生命周期；Chat 模式或未启用
            // 本地 Linux 的 Agent Run 不能只暴露工具、等到执行阶段才失败。
            if case .localStdio = available.server.transport,
               !includeLocalLinuxTools {
                return nil
            }
            let builtInCategory = MCPBuiltInAppToolServer.category(for: available.server.id)
            if !chatToolsEnabled {
                let isIncludedAgentBuiltIn = (builtInCategory == .linux && includeLocalLinuxTools)
                    || (builtInCategory == .file && includeLocalLinuxTools)
                guard isIncludedAgentBuiltIn else { return nil }
            }
            if builtInCategory == .conversation,
               !includeConversationAgentTools {
                return nil
            }
            if builtInCategory == .linux,
               !includeLocalLinuxTools {
                return nil
            }
            if builtInCategory == .browser,
               !includeBrowserAgentTools {
                return nil
            }
            if available.server.approvalPolicy(for: available.tool.toolId) == .alwaysDeny {
                return nil
            }
            let description: String
            if let desc = available.tool.description, !desc.isEmpty {
                description = "[\(available.server.displayName)] \(desc)"
            } else {
                let fallback = String(
                    format: NSLocalizedString("MCP 工具 %@", comment: "MCP tool fallback description sent to model"),
                    available.tool.toolId
                )
                description = "[\(available.server.displayName)] \(fallback)"
            }
            let parameters = available.tool.inputSchema ?? .dictionary([
                "type": .string("object"),
                "additionalProperties": .bool(true)
            ])
            return InternalToolDefinition(name: available.internalName, description: description, parameters: parameters, isBlocking: true)
        }
        return chatTools
    }

    public func executeToolFromChat(
        toolName: String,
        argumentsJSON: String,
        sourceSessionID: UUID? = nil,
        sourceToolCallID: String? = nil,
        sourceAgentRunID: UUID? = nil,
        triggeringMessageID: UUID? = nil,
        approvedLocalLinuxCommandRuleIDs: Set<UUID> = []
    ) async throws -> String {
        guard let routed = routedTools[toolName] else {
            throw MCPChatBridgeError.unknownTool
        }
        let builtInCategory = MCPBuiltInAppToolServer.category(for: routed.server.id)
        let activeLocalAgentRun = sourceAgentRunID
            .flatMap { Persistence.loadLocalAgentRun(id: $0) }
            .flatMap { run in
                run.state == .running && run.context.mode == .agent ? run : nil
            }
        let isAgentBuiltIn = activeLocalAgentRun != nil
            && (builtInCategory == .linux || builtInCategory == .file)
        guard chatToolsEnabled || isAgentBuiltIn else {
            throw MCPChatBridgeError.toolGroupDisabled(
                NSLocalizedString("MCP 工具", comment: "MCP tool group display name")
            )
        }
        if routed.server.approvalPolicy(for: routed.tool.toolId) == .alwaysDeny {
            throw MCPChatBridgeError.toolDeniedByPolicy(displayName(for: routed))
        }
        if case .localStdio = routed.server.transport {
            guard activeLocalAgentRun != nil else {
                // 工具定义已在请求准备阶段隔离；执行层仍要拒绝历史或伪造调用，
                // 避免已手动连接的 stdio 客户端绕过 Chat 模式边界。
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("当前会话不是 Agent 模式。", comment: "Local Agent mode required error")
                )
            }
        }
        if case .localStdio(let configuration) = routed.server.transport,
           configuration.launchPolicy == .manual,
           clients[routed.server.id] == nil {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("该本地 MCP 设置为仅手动连接，请先在 MCP 页面连接。", comment: "Manual local stdio MCP connection required")
            )
        }
        let startedAt = Date()
        appendGovernanceLog(level: .info, category: .toolCall, serverID: routed.server.id, message: String(format: NSLocalizedString("开始执行聊天工具：%@", comment: "MCP governance chat tool started"), routed.tool.toolId))
        var inputs = try decodeJSONDictionary(from: argumentsJSON)
        if builtInCategory == .conversation || builtInCategory == .linux || builtInCategory == .file || builtInCategory == .browser {
            inputs.removeValue(forKey: MCPBuiltInAppToolServer.conversationSourceSessionIDArgument)
            inputs.removeValue(forKey: MCPBuiltInAppToolServer.conversationToolCallIDArgument)
            guard let sourceSessionID,
                  let sourceToolCallID,
                  !sourceToolCallID.isEmpty else {
                throw ConversationRuntimeError.sessionNotFound
            }
            // 这两个字段只在 MCP 路由内部传递，不进入工具 schema，也不能由模型决定来源身份。
            inputs[MCPBuiltInAppToolServer.conversationSourceSessionIDArgument] = .string(
                sourceSessionID.uuidString
            )
            inputs[MCPBuiltInAppToolServer.conversationToolCallIDArgument] = .string(sourceToolCallID)
        }
        if builtInCategory == .linux
            || builtInCategory == .browser
            || builtInCategory == .file {
            inputs.removeValue(forKey: MCPBuiltInAppToolServer.localAgentRunIDArgument)
            inputs.removeValue(forKey: MCPBuiltInAppToolServer.localAgentTriggeringMessageIDArgument)
            inputs.removeValue(forKey: MCPBuiltInAppToolServer.localAgentSelectedMCPServerIDsArgument)
            inputs.removeValue(forKey: MCPBuiltInAppToolServer.localAgentApprovedCommandRuleIDsArgument)
        }
        if builtInCategory == .linux
            || builtInCategory == .browser
            || (builtInCategory == .file && sourceAgentRunID != nil) {
            guard let sourceAgentRunID else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("本地 Agent 工具缺少 Run 标识。", comment: "Missing Agent run ID for local Agent tool")
                )
            }
            inputs[MCPBuiltInAppToolServer.localAgentRunIDArgument] = .string(sourceAgentRunID.uuidString)
            if let triggeringMessageID {
                inputs[MCPBuiltInAppToolServer.localAgentTriggeringMessageIDArgument] = .string(
                    triggeringMessageID.uuidString
                )
            }
            let selectedServerIDs = servers
                .filter(\.isSelectedForChat)
                .map { JSONValue.string($0.id.uuidString) }
            inputs[MCPBuiltInAppToolServer.localAgentSelectedMCPServerIDsArgument] = .array(selectedServerIDs)
            inputs[MCPBuiltInAppToolServer.localAgentApprovedCommandRuleIDsArgument] = .array(
                approvedLocalLinuxCommandRuleIDs
                    .sorted { $0.uuidString < $1.uuidString }
                    .map { .string($0.uuidString) }
            )
        }
        let callID = UUID()
        var localInstanceKey: MCPLocalStdioInstanceKey?
        do {
            let clientOverride: MCPClient?
            if case .localStdio(let configuration) = routed.server.transport,
               configuration.launchPolicy == .onDemand,
               let sourceAgentRunID {
                guard let sourceSessionID else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("本地 MCP 缺少 Agent 会话标识。", comment: "Missing Agent session for local stdio MCP")
                    )
                }
                let selectedServerIDs = servers.filter(\.isSelectedForChat).map(\.id)
                _ = try await LocalAgentRuntimeContextManager.shared.beginRun(
                    sessionID: sourceSessionID,
                    triggeringMessageID: triggeringMessageID,
                    toolCallID: sourceToolCallID,
                    runID: sourceAgentRunID,
                    selectedMCPServerIDs: selectedServerIDs
                )
                guard let run = Persistence.loadLocalAgentRun(id: sourceAgentRunID) else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("找不到本地 MCP 对应的 Agent Run。", comment: "Missing Agent run for local stdio MCP")
                    )
                }
                let acquired = try await acquireLocalStdioClient(
                    server: routed.server,
                    context: run.context,
                    approvedCommandRuleIDs: approvedLocalLinuxCommandRuleIDs
                )
                localInstanceKey = acquired.key
                clientOverride = acquired.client
            } else {
                clientOverride = nil
            }
            defer {
                if let localInstanceKey {
                    releaseLocalStdioClient(key: localInstanceKey)
                }
            }
            let result = try await executeManagedToolCall(
                callID: callID,
                serverID: routed.server.id,
                toolId: routed.tool.toolId,
                inputs: inputs,
                options: defaultManagedToolCallOptions(
                    timeout: defaultChatToolCallTimeout,
                    reason: NSLocalizedString("聊天工具调用超时", comment: "MCP chat tool timeout reason")
                ),
                clientOverride: clientOverride
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            appendGovernanceLog(level: .info, category: .toolCall, serverID: routed.server.id, message: String(format: NSLocalizedString("聊天工具执行成功：%@，耗时 %.2f 秒。", comment: "MCP governance chat tool succeeded"), routed.tool.toolId, elapsed))
            return result.prettyPrinted()
        } catch is CancellationError {
            appendGovernanceLog(level: .warning, category: .toolCall, serverID: routed.server.id, message: String(format: NSLocalizedString("聊天工具执行已取消：%@", comment: "MCP governance chat tool cancelled"), routed.tool.toolId))
            throw MCPChatBridgeError.toolCancelled(displayName(for: routed))
        } catch {
            appendGovernanceLog(level: .error, category: .toolCall, serverID: routed.server.id, message: String(format: NSLocalizedString("聊天工具执行失败：%@，错误=%@", comment: "MCP governance chat tool failed"), routed.tool.toolId, error.localizedDescription))
            throw error
        }
    }

    public func internalName(for tool: MCPAvailableTool) -> String {
        tool.internalName
    }

    public func displayLabel(for toolName: String) -> String? {
        guard let routed = routedTools[toolName] else { return nil }
        return "[\(routed.server.displayName)] \(routed.tool.toolId)"
    }

    public func isConversationTool(_ toolName: String) -> Bool {
        guard let routed = routedTools[toolName] else { return false }
        return MCPBuiltInAppToolServer.category(for: routed.server.id) == .conversation
            && ConversationToolDefinitions.contains(routed.tool.toolId)
    }

    public func isLocalLinuxTool(_ toolName: String) -> Bool {
        guard let routed = routedTools[toolName] else { return false }
        return MCPBuiltInAppToolServer.category(for: routed.server.id) == .linux
            && LocalLinuxToolDefinitions.contains(routed.tool.toolId)
    }

    public func localLinuxToolID(for toolName: String) -> String? {
        guard let routed = routedTools[toolName],
              MCPBuiltInAppToolServer.category(for: routed.server.id) == .linux,
              LocalLinuxToolDefinitions.contains(routed.tool.toolId) else {
            return nil
        }
        return routed.tool.toolId
    }

    public func localStdioCommandRuleMatch(
        for toolName: String,
        sourceAgentRunID: UUID?
    ) async -> LocalLinuxCommandRuleMatch? {
        guard AppConfigStore.boolValue(for: .localLinuxCommandSafetyEnabled),
              let routed = routedTools[toolName],
              let sourceAgentRunID,
              let run = Persistence.loadLocalAgentRun(id: sourceAgentRunID) else {
            return nil
        }
        let frozenServer = run.context.selectedMCPServerConfigurations?
            .first(where: { $0.id == routed.server.id }) ?? routed.server
        guard case .localStdio(let configuration) = frozenServer.transport,
              configuration.launchPolicy == .onDemand else { return nil }
        guard let snapshot = try? await LocalLinuxProcessEnvironmentProvider.shared.snapshot(
            referenceIDs: configuration.environmentVariableIDs,
            inheritGlobalEnvironment: configuration.inheritLocalLinuxEnvironment,
            additional: configuration.environment,
            frozenGlobalValues: run.context.environmentValues,
            frozenReferences: run.context.environmentReferenceSnapshots,
            frozenRedactionValues: run.context.environmentRedactionValues
        ) else { return nil }
        let workspaceID = configuration.workspaceID ?? run.context.workspaceID
        let key = MCPLocalStdioInstanceKey(
            serverID: routed.server.id,
            workspaceID: workspaceID,
            environmentSnapshotHash: snapshot.hash,
            configurationHash: configuration.hashValue
        )
        guard localStdioInstances[key] == nil, localStdioConnectionTasks[key] == nil else {
            return nil
        }
        let command = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        let request = LocalLinuxJobRequest(
            executable: command,
            arguments: [command] + configuration.arguments,
            workingDirectory: configuration.workingDirectory,
            timeoutSeconds: 0,
            outputLimitBytes: 0
        )
        return await LocalLinuxApprovalPolicy.shared.evaluate(
            request: request,
            kind: .localMCP,
            isEnabled: true
        )
    }

    public func isToolEnabled(serverID: UUID, toolId: String) -> Bool {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return true
        }
        return server.isToolEnabled(toolId)
    }

    public func setToolEnabled(serverID: UUID, toolId: String, isEnabled: Bool) {
        guard var server = servers.first(where: { $0.id == serverID }) else { return }
        server.setToolEnabled(toolId, isEnabled: isEnabled)
        let stateText = isEnabled
            ? NSLocalizedString("启用", comment: "MCP enabled state")
            : NSLocalizedString("禁用", comment: "MCP disabled state")
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: String(format: NSLocalizedString("工具 %@ 已%@。", comment: "MCP governance tool enabled changed"), toolId, stateText))
        save(server: server)
    }

    public func approvalPolicy(serverID: UUID, toolId: String) -> MCPToolApprovalPolicy {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return .askEveryTime
        }
        return server.approvalPolicy(for: toolId)
    }

    public func approvalPolicy(for toolName: String) -> MCPToolApprovalPolicy? {
        guard chatToolsEnabled else { return .alwaysDeny }
        guard let routed = routedTools[toolName] else { return nil }
        return routed.server.approvalPolicy(for: routed.tool.toolId)
    }

    public func setToolApprovalPolicy(serverID: UUID, toolId: String, policy: MCPToolApprovalPolicy) {
        guard var server = servers.first(where: { $0.id == serverID }) else { return }
        server.setApprovalPolicy(policy, for: toolId)
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: String(format: NSLocalizedString("工具 %@ 审批策略已更新为 %@。", comment: "MCP governance tool approval policy changed"), toolId, policy.rawValue))
        save(server: server)
    }

    public func currentResumptionToken(for serverID: UUID) async -> String? {
        guard let transport = streamingTransports[serverID] as? MCPResumptionControllableTransport else {
            return nil
        }
        return await transport.currentResumptionToken()
    }

    public func updateResumptionToken(_ token: String?, for serverID: UUID) async {
        guard let transport = streamingTransports[serverID] as? MCPResumptionControllableTransport else {
            return
        }
        await transport.updateResumptionToken(token)
        persistResumptionToken(for: serverID)
    }

    public func terminateRemoteSession(for serverID: UUID) async {
        guard let transport = streamingTransports[serverID] as? MCPResumptionControllableTransport else {
            return
        }
        await transport.terminateSession()
        let client = removeConnectionArtifacts(for: serverID)
        await client?.disconnect()
        persistResumptionToken(nil, for: serverID)
        updateStatus(for: serverID) {
            $0.connectionState = .idle
            $0.info = nil
            $0.isBusy = false
        }
        appendGovernanceLog(level: .info, category: .lifecycle, serverID: serverID, message: NSLocalizedString("远端会话已终止，连接状态已重置。", comment: "MCP governance remote session terminated"))
    }

    public func connectedServers() -> [MCPServerConfiguration] {
        servers.filter {
            if let status = serverStatuses[$0.id] {
                if case .ready = status.connectionState { return true }
            }
            return false
        }
    }

    public func selectedServers() -> [MCPServerConfiguration] {
        servers.filter {
            guard let status = serverStatuses[$0.id], status.isSelectedForChat else { return false }
            return true
        }
    }
}
