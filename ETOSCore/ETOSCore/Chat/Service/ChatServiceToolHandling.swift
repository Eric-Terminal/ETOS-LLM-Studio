// ============================================================================
// ChatServiceToolHandling.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的工具调用执行、工具结果写回与记忆搜索结果序列化。
// ============================================================================

import Foundation
import os.log

extension ChatService {
    struct ToolCallOutcome {
        let message: ChatMessage
        let toolResult: String?
        let shouldAwaitUserSupplement: Bool
    }
    
    /// 处理单个工具调用
    func handleToolCall(_ toolCall: InternalToolCall, sessionID: UUID? = nil) async -> ToolCallOutcome {
        logger.info("正在处理工具调用: \(toolCall.toolName)")

        var content = ""
        var displayResult: String?
        var shouldAwaitUserSupplement = false
        let policyDeniedText: (String) -> String = {
            String(format: NSLocalizedString("%@ 已被策略禁止调用。", comment: "Tool result when policy denies a call"), $0)
        }
        let callFailedText: (String, String) -> String = {
            String(format: NSLocalizedString("%@ 调用失败：%@", comment: "Tool result when a call fails"), $0, $1)
        }
        let userDeniedText: (String) -> String = {
            String(format: NSLocalizedString("%@ 调用已被用户拒绝。", comment: "Tool result when user denies a call"), $0)
        }

        switch toolCall.toolName {
        case "save_memory":
            struct SaveMemoryArgs: Decodable {
                let content: String
                let kind: String?
                let source: String?
                let importance: Double?
                let confidence: Double?
                let entities: [String]?
                let valid_from: String?
                let valid_until: String?
            }
            if let argsData = toolCall.arguments.data(using: .utf8),
               let args = try? JSONDecoder().decode(SaveMemoryArgs.self, from: argsData) {
                let formatter = ISO8601DateFormatter()
                let source: MemorySource = args.source == "assistant_action" ? .assistantAction : .userStatement
                await self.memoryManager.addMemory(
                    MemoryWriteRequest(
                        content: args.content,
                        kind: MemoryKind(rawValue: args.kind ?? "") ?? .semantic,
                        source: source,
                        importance: args.importance ?? 0.5,
                        confidence: args.confidence ?? 1,
                        entities: args.entities ?? [],
                        validFrom: args.valid_from.flatMap(formatter.date(from:)),
                        validUntil: args.valid_until.flatMap(formatter.date(from:)),
                        sourceSessionID: sessionID
                    )
                )
                content = String(format: NSLocalizedString("成功将内容 \"%@\" 存入记忆。", comment: "Save memory tool result"), args.content)
                displayResult = content
                logger.info("  - 记忆保存成功。")
                scheduleLongTermMemoryConsolidationIfNeeded(
                    for: sessionID,
                    enableMemory: true
                )
            } else {
                content = NSLocalizedString("错误：无法解析 save_memory 的参数。", comment: "Save memory args parse error")
                displayResult = content
                logger.error("  - 无法解析 save_memory 的参数: \(toolCall.arguments)")
            }

        case "search_memory":
            struct SearchMemoryArgs: Decodable {
                let mode: String
                let query: String
                let count: Int?
            }

            guard let argsData = toolCall.arguments.data(using: .utf8),
                  let args = try? JSONDecoder().decode(SearchMemoryArgs.self, from: argsData) else {
                content = NSLocalizedString("错误：无法解析 search_memory 的参数。请提供 mode、query，并可选 count。", comment: "Search memory args parse error")
                displayResult = content
                logger.error("  - 无法解析 search_memory 的参数: \(toolCall.arguments)")
                break
            }

            let mode = args.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                content = NSLocalizedString("错误：search_memory 的 query 不能为空。", comment: "Search memory empty query error")
                displayResult = content
                logger.error("  - search_memory query 为空。")
                break
            }

            let requestedCount = max(1, args.count ?? resolvedMemoryTopK())
            var resolvedMemories: [MemoryItem] = []
            switch mode {
            case "hybrid":
                resolvedMemories = await memoryManager.searchMemoriesHybrid(query: query, topK: requestedCount)
            case "vector":
                resolvedMemories = await memoryManager.searchMemories(query: query, topK: requestedCount)
            case "keyword":
                resolvedMemories = await memoryManager.searchMemoriesByKeyword(query: query, topK: requestedCount)
            default:
                content = NSLocalizedString("错误：search_memory 的 mode 仅支持 hybrid、vector 或 keyword。", comment: "Search memory unsupported mode error")
                displayResult = content
                logger.error("  - search_memory mode 不支持: \(mode)")
                break
            }

            if !content.isEmpty {
                break
            }

            content = serializeMemorySearchResult(
                mode: mode,
                query: query,
                requestedCount: requestedCount,
                memories: resolvedMemories
            )
            displayResult = content
            logger.info("  - search_memory 检索完成: mode=\(mode), queryLength=\(query.count), resultCount=\(resolvedMemories.count)")

        case _ where MCPManager.isMCPToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                MCPManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let approvalPolicy = await MainActor.run {
                MCPManager.shared.approvalPolicy(for: toolCall.toolName) ?? .askEveryTime
            }

            switch approvalPolicy {
            case .alwaysDeny:
                content = policyDeniedText(toolLabel)
                displayResult = content
                logger.info("  - MCP 工具调用被策略拒绝: \(toolCall.toolName)")
            case .alwaysAllow:
                do {
                    let result = try await MCPManager.shared.executeToolFromChat(toolName: toolCall.toolName, argumentsJSON: toolCall.arguments)
                    content = result
                    displayResult = result
                    logger.info("  - MCP 工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
                    logger.error("  - MCP 工具调用失败: \(error.localizedDescription)")
                }
            case .askEveryTime:
                let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                    toolName: toolCall.toolName,
                    displayName: toolLabel,
                    arguments: toolCall.arguments,
                    sourceSessionID: sessionID,
                    toolCallID: toolCall.id
                )
                switch permissionDecision {
                case .deny:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    logger.info("  - MCP 工具调用被用户拒绝: \(toolCall.toolName)")
                case .supplement:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    shouldAwaitUserSupplement = true
                    logger.info("  - MCP 工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
                case .allowOnce, .allowForTool, .allowAll:
                    do {
                        let result = try await MCPManager.shared.executeToolFromChat(toolName: toolCall.toolName, argumentsJSON: toolCall.arguments)
                        content = result
                        displayResult = result
                        logger.info("  - MCP 工具调用成功: \(toolCall.toolName)")
                    } catch {
                        content = callFailedText(toolLabel, error.localizedDescription)
                        displayResult = content
                        logger.error("  - MCP 工具调用失败: \(error.localizedDescription)")
                    }
                }
            }

        case _ where ShortcutToolManager.isShortcutToolName(toolCall.toolName):
            let toolLabel = await ShortcutToolManager.shared.displayLabel(for: toolCall.toolName) ?? toolCall.toolName
            let shortcutToolsEnabled = await MainActor.run { ShortcutToolManager.shared.chatToolsEnabled }
            guard shortcutToolsEnabled else {
                content = NSLocalizedString("快捷指令工具总开关已关闭。", comment: "Shortcut tool disabled result")
                displayResult = content
                logger.info("  - 快捷指令工具调用被总开关拒绝: \(toolCall.toolName)")
                break
            }
            let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                toolName: toolCall.toolName,
                displayName: toolLabel,
                arguments: toolCall.arguments,
                sourceSessionID: sessionID,
                toolCallID: toolCall.id
            )
            switch permissionDecision {
            case .deny:
                content = userDeniedText(toolLabel)
                displayResult = content
                logger.info("  - 快捷指令工具调用被用户拒绝: \(toolCall.toolName)")
            case .supplement:
                content = userDeniedText(toolLabel)
                displayResult = content
                shouldAwaitUserSupplement = true
                logger.info("  - 快捷指令工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
            case .allowOnce, .allowForTool, .allowAll:
                do {
                    let result = try await ShortcutToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments
                    )
                    content = result
                    displayResult = result
                    logger.info("  - 快捷指令工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
                    logger.error("  - 快捷指令工具调用失败: \(error.localizedDescription)")
                }
            }

        case _ where SkillManager.isSkillToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                SkillManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let skillsEnabled = await MainActor.run { SkillManager.shared.chatToolsEnabled }
            guard skillsEnabled else {
                content = NSLocalizedString("Agent Skills 总开关已关闭。", comment: "Agent Skills disabled result")
                displayResult = content
                logger.info("  - Agent Skills 调用被总开关拒绝: \(toolCall.toolName)")
                break
            }

            do {
                let result = try await SkillManager.shared.executeToolFromChat(
                    toolName: toolCall.toolName,
                    argumentsJSON: toolCall.arguments
                )
                content = result
                displayResult = result
                logger.info("  - Agent Skills 调用成功: \(toolCall.toolName)")
            } catch {
                content = callFailedText(toolLabel, error.localizedDescription)
                displayResult = content
                logger.error("  - Agent Skills 调用失败: \(error.localizedDescription)")
            }

        case _ where AppToolManager.isAppToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                AppToolManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let isBuiltInAppTool = AppToolManager.isBuiltInToolName(toolCall.toolName)
            let appToolsEnabled = await MainActor.run { AppToolManager.shared.chatToolsEnabled }
            guard appToolsEnabled || isBuiltInAppTool else {
                content = NSLocalizedString("拓展工具总开关已关闭。", comment: "App tool disabled result")
                displayResult = content
                logger.info("  - 拓展工具调用被总开关拒绝: \(toolCall.toolName)")
                break
            }
            let approvalPolicy = await MainActor.run {
                AppToolManager.shared.approvalPolicy(for: toolCall.toolName) ?? .askEveryTime
            }
            switch approvalPolicy {
            case .alwaysDeny:
                content = policyDeniedText(toolLabel)
                displayResult = content
                logger.info("  - 拓展工具调用被策略拒绝: \(toolCall.toolName)")
            case .alwaysAllow:
                do {
                    let result = try await AppToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments
                    )
                    content = result
                    displayResult = result
                    if toolCall.toolName == AppToolKind.askUserInput.toolName {
                        shouldAwaitUserSupplement = true
                    }
                    logger.info("  - 拓展工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
                    logger.error("  - 拓展工具调用失败: \(error.localizedDescription)")
                }
            case .askEveryTime:
                let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                    toolName: toolCall.toolName,
                    displayName: toolLabel,
                    arguments: toolCall.arguments,
                    sourceSessionID: sessionID,
                    toolCallID: toolCall.id
                )
                switch permissionDecision {
                case .deny:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    logger.info("  - 拓展工具调用被用户拒绝: \(toolCall.toolName)")
                case .supplement:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    shouldAwaitUserSupplement = true
                    logger.info("  - 拓展工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
                case .allowOnce, .allowForTool, .allowAll:
                    do {
                        let result = try await AppToolManager.shared.executeToolFromChat(
                            toolName: toolCall.toolName,
                            argumentsJSON: toolCall.arguments
                        )
                        content = result
                        displayResult = result
                        if toolCall.toolName == AppToolKind.askUserInput.toolName {
                            shouldAwaitUserSupplement = true
                        }
                        logger.info("  - 拓展工具调用成功: \(toolCall.toolName)")
                    } catch {
                        content = callFailedText(toolLabel, error.localizedDescription)
                        displayResult = content
                        logger.error("  - 拓展工具调用失败: \(error.localizedDescription)")
                    }
                }
            }

        default:
            content = String(format: NSLocalizedString("错误：未知的工具名称 %@。", comment: "Unknown tool result"), toolCall.toolName)
            displayResult = content
            logger.error("  - 未知的工具名称: \(toolCall.toolName)")
        }

        let message = ChatMessage(
            role: .tool,
            content: content,
            toolCalls: [
                InternalToolCall(
                    id: toolCall.id,
                    toolName: toolCall.toolName,
                    arguments: toolCall.arguments,
                    result: displayResult,
                    providerSpecificFields: toolCall.providerSpecificFields
                )
            ]
        )

        return ToolCallOutcome(
            message: message,
            toolResult: displayResult,
            shouldAwaitUserSupplement: shouldAwaitUserSupplement
        )
    }

    func serializeMemorySearchResult(
        mode: String,
        query: String,
        requestedCount: Int,
        memories: [MemoryItem]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let items: [[String: Any]] = memories.map { memory in
            var item: [String: Any] = [
                "id": memory.id.uuidString,
                "content": memory.content,
                "kind": memory.kind.rawValue,
                "source": memory.source.rawValue,
                "importance": memory.importance,
                "confidence": memory.confidence,
                "entities": memory.entities,
                "accessCount": memory.accessCount
            ]
            if let validFrom = memory.validFrom {
                item["validFrom"] = formatter.string(from: validFrom)
            }
            if let validUntil = memory.validUntil {
                item["validUntil"] = formatter.string(from: validUntil)
            }
            if shouldSendMemoryUpdateTime() {
                item["updatedAt"] = formatter.string(from: memory.updatedAt ?? memory.createdAt)
            }
            return item
        }
        let payload: [String: Any] = [
            "mode": mode,
            "query": query,
            "requestedCount": requestedCount,
            "returnedCount": memories.count,
            "items": items
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            return String(data: data, encoding: .utf8) ?? NSLocalizedString("错误：检索结果序列化失败。", comment: "Search memory serialize fallback")
        } catch {
            logger.error("search_memory 结果序列化失败：\(error.localizedDescription)")
            return NSLocalizedString("错误：检索结果序列化失败。", comment: "Search memory serialize error")
        }
    }

    @MainActor
    func attachToolResult(_ result: String, to toolCallID: String, toolName: String, loadingMessageID: UUID, sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        var message = messages[messageIndex]
        guard var toolCalls = message.toolCalls else { return }
        var callIndex = toolCalls.firstIndex(where: { $0.id == toolCallID })
        if callIndex == nil {
            let matchedByName = toolCalls.enumerated().filter { $0.element.toolName == toolName }
            if matchedByName.count == 1 {
                callIndex = matchedByName.first?.offset
                logger.warning("未找到匹配的工具调用 ID，已按名称 '\(toolName)' 回退匹配结果。")
            }
        }
        guard let resolvedIndex = callIndex else { return }
        toolCalls[resolvedIndex].result = result
        message.toolCalls = toolCalls
        messages[messageIndex] = message
        persistAndPublishMessages(messages, for: sessionID)
    }

    func ensureToolCallsVisible(_ toolCalls: [InternalToolCall], in loadingMessageID: UUID, sessionID: UUID) {
        guard !toolCalls.isEmpty else { return }
        var messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        var message = messages[messageIndex]
        var existingCalls = message.toolCalls ?? []
        var didChange = false

        for call in toolCalls {
            if let existingIndex = existingCalls.firstIndex(where: { $0.id == call.id }) {
                let existingResult = existingCalls[existingIndex].result
                if existingCalls[existingIndex].toolName != call.toolName
                    || existingCalls[existingIndex].arguments != call.arguments
                    || existingCalls[existingIndex].providerSpecificFields != call.providerSpecificFields {
                    existingCalls[existingIndex] = InternalToolCall(
                        id: call.id,
                        toolName: call.toolName,
                        arguments: call.arguments,
                        result: existingResult,
                        providerSpecificFields: call.providerSpecificFields
                    )
                    didChange = true
                }
            } else {
                existingCalls.append(call)
                didChange = true
            }
        }

        guard didChange else { return }
        message.toolCalls = existingCalls
        messages[messageIndex] = message
        persistAndPublishMessages(messages, for: sessionID)
    }
}
