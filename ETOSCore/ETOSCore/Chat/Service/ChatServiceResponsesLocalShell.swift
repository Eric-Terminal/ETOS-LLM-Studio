// ============================================================================
// ChatServiceResponsesLocalShell.swift
// ETOS LLM Studio
//
// 执行 OpenAI Responses 的 shell_call，并把现有 Linux 调度、命令规则、用户审批
// 和隐私脱敏输出转换为官方 shell_call_output 结构。
// ============================================================================

import Foundation

extension ChatService {
    struct ResponsesLocalShellExecution {
        let content: String
        let resultDisposition: InternalToolCallResultDisposition
        let shouldAwaitUserSupplement: Bool
    }

    private struct ResponsesLocalShellArguments: Decodable {
        let commands: [String]
        let timeoutMS: Int?
        let maxOutputLength: Int?

        enum CodingKeys: String, CodingKey {
            case commands
            case timeoutMS = "timeout_ms"
            case maxOutputLength = "max_output_length"
        }
    }

    func executeResponsesLocalShellCall(
        _ toolCall: InternalToolCall,
        sessionID: UUID,
        runID: UUID,
        triggeringMessageID: UUID?
    ) async -> ResponsesLocalShellExecution {
        guard let data = toolCall.arguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ResponsesLocalShellArguments.self, from: data),
              !arguments.commands.isEmpty,
              arguments.timeoutMS.map({ $0 > 0 }) ?? true,
              arguments.maxOutputLength.map({ $0 > 0 }) ?? true,
              arguments.commands.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.contains("\0")
              }) else {
            return ResponsesLocalShellExecution(
                content: responsesShellOutputJSON(
                    outputs: [responsesShellFailure(NSLocalizedString("Responses shell_call 参数无效。", comment: "Invalid Responses shell call"))],
                    maxOutputLength: nil
                ),
                resultDisposition: .completed,
                shouldAwaitUserSupplement: false
            )
        }

        await OpenAIResponsesLocalShellRuntime.shared.activateReferencedSkills(
            argumentsJSON: toolCall.arguments,
            runID: runID
        )

        let timeoutSeconds: Double? = arguments.timeoutMS.flatMap { value in
            guard value > 0 else { return nil }
            return min(Double(value) / 1_000, 3_600)
        }
        let outputCaptureLength = arguments.maxOutputLength.map { min($0, 16_777_216) }
        let selectedMCPServerIDs = Persistence.loadLocalAgentRun(id: runID)?
            .context.selectedMCPServerIDs ?? []
        let configuredPolicy = responsesLocalShellApprovalPolicy()
        var outputs: [[String: Any]] = []
        var resultDisposition: InternalToolCallResultDisposition = .completed
        var shouldAwaitUserSupplement = false

        commandLoop: for command in arguments.commands {
            let shellArguments = responsesLinuxShellArgumentsJSON(
                command: command,
                timeoutSeconds: timeoutSeconds
            )
            let ruleMatch = try? await LocalLinuxToolExecutor.shared.commandRuleMatch(
                toolName: LocalLinuxToolName.shell.rawValue,
                argumentsJSON: shellArguments
            )
            let needsConfirmation = ruleMatch?.action == .confirm
            let effectivePolicy: MCPToolApprovalPolicy = needsConfirmation && configuredPolicy == .alwaysAllow
                ? .askEveryTime
                : configuredPolicy
            var approvedRuleIDs: Set<UUID> = []

            switch effectivePolicy {
            case .alwaysDeny:
                outputs.append(responsesShellFailure(NSLocalizedString("本地 Shell 已被策略禁止调用。", comment: "Responses local shell policy denied")))
                resultDisposition = .rejected
                continue
            case .alwaysAllow:
                break
            case .askEveryTime:
                let decision = await ToolPermissionCenter.shared.requestPermission(
                    toolName: OpenAIResponsesLocalShellProtocol.toolName,
                    displayName: NSLocalizedString("Responses 本地 Shell", comment: "Responses local shell permission title"),
                    arguments: command,
                    sourceSessionID: sessionID,
                    toolCallID: toolCall.id
                )
                guard decision == .allowOnce || decision == .allowForTool || decision == .allowAll else {
                    outputs.append(responsesShellFailure(NSLocalizedString("Responses 本地 Shell 调用已被用户拒绝。", comment: "Responses local shell user denied")))
                    resultDisposition = .rejected
                    shouldAwaitUserSupplement = decision == .supplement
                    if shouldAwaitUserSupplement { break commandLoop }
                    continue
                }
                if let ruleMatch, ruleMatch.action == .confirm {
                    approvedRuleIDs.insert(ruleMatch.ruleID)
                }
            }

            do {
                let result = try await LocalLinuxToolExecutor.shared.execute(
                    toolName: LocalLinuxToolName.shell.rawValue,
                    argumentsJSON: shellArguments,
                    sessionID: sessionID,
                    runID: runID,
                    triggeringMessageID: triggeringMessageID,
                    toolCallID: toolCall.id,
                    selectedMCPServerIDs: selectedMCPServerIDs,
                    approvedCommandRuleIDs: approvedRuleIDs
                )
                outputs.append(responsesShellOutput(fromLinuxResult: result, maximumLength: outputCaptureLength))
            } catch {
                outputs.append(responsesShellFailure(error.localizedDescription))
            }
        }

        if outputs.count < arguments.commands.count {
            let skipped = NSLocalizedString("等待用户补充，命令尚未执行。", comment: "Responses local shell command skipped for supplement")
            outputs.append(contentsOf: repeatElement(
                responsesShellFailure(skipped),
                count: arguments.commands.count - outputs.count
            ))
        }
        return ResponsesLocalShellExecution(
            content: responsesShellOutputJSON(outputs: outputs, maxOutputLength: arguments.maxOutputLength),
            resultDisposition: resultDisposition,
            shouldAwaitUserSupplement: shouldAwaitUserSupplement
        )
    }

    private func responsesLocalShellApprovalPolicy() -> MCPToolApprovalPolicy {
        let linuxServerID = MCPBuiltInAppToolServer.serverID(for: .linux)
        return MCPServerStore.loadServers()
            .first(where: { $0.id == linuxServerID })?
            .approvalPolicy(for: LocalLinuxToolName.shell.rawValue) ?? .askEveryTime
    }

    private func responsesLinuxShellArgumentsJSON(command: String, timeoutSeconds: Double?) -> String {
        var payload: [String: Any] = ["script": command]
        if let timeoutSeconds {
            payload["timeout_seconds"] = timeoutSeconds
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func responsesShellOutput(fromLinuxResult result: String, maximumLength: Int?) -> [String: Any] {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return responsesShellFailure(result)
        }
        let combinedOutput = truncatedResponsesShellText(payload["output"] as? String ?? "", maximumLength: maximumLength)
        let completionReason = payload["completion_reason"] as? String
        let outcome: [String: Any]
        if completionReason == LocalLinuxCompletionReason.timedOut.rawValue {
            outcome = ["type": "timeout"]
        } else {
            let exitCode = (payload["exit_code"] as? NSNumber)?.intValue
                ?? (payload["signal"] as? NSNumber).map { 128 + $0.intValue }
                ?? -1
            outcome = ["type": "exit", "exit_code": exitCode]
        }
        return [
            "stdout": combinedOutput,
            "stderr": "",
            "outcome": outcome
        ]
    }

    private func responsesShellFailure(_ message: String) -> [String: Any] {
        [
            "stdout": "",
            "stderr": message,
            "outcome": ["type": "exit", "exit_code": -1]
        ]
    }

    private func responsesShellOutputJSON(outputs: [[String: Any]], maxOutputLength: Int?) -> String {
        var payload: [String: Any] = ["output": outputs]
        if let maxOutputLength {
            payload["max_output_length"] = maxOutputLength
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return #"{"output":[]}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func truncatedResponsesShellText(_ text: String, maximumLength: Int?) -> String {
        guard let maximumLength, text.count > maximumLength else { return text }
        return String(text.prefix(maximumLength))
    }
}
