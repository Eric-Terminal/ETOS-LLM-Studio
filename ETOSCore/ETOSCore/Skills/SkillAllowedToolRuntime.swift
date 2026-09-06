// ============================================================================
// SkillAllowedToolRuntime.swift
// ETOS LLM Studio
//
// 在 Agent Run 内记录已经加载的 Skill，并把 allowed-tools 同时应用到后续工具
// 暴露和最终执行入口。Run 外不保留状态，避免一次技能选择污染其他会话。
// ============================================================================

import Foundation

public actor SkillAllowedToolRuntime {
    public static let shared = SkillAllowedToolRuntime()

    private var activeSkillsByRunID: [UUID: [String: [String]]] = [:]

    public init() {}

    public func activate(skill: SkillRunSnapshot, runID: UUID) {
        activate(skillName: skill.skillName, allowedTools: skill.allowedTools, runID: runID)
    }

    public func activate(skillName: String, allowedTools: [String], runID: UUID) {
        activeSkillsByRunID[runID, default: [:]][skillName] = allowedTools
    }

    public func finishRun(id: UUID) {
        activeSkillsByRunID[id] = nil
    }

    public func isToolAllowed(
        _ toolName: String,
        runID: UUID,
        exemptToolNames: Set<String> = [SkillManager.chatToolName]
    ) -> Bool {
        if exemptToolNames.contains(toolName) { return true }
        let restrictions = activeSkillsByRunID[runID]?.values.filter { !$0.isEmpty } ?? []
        guard !restrictions.isEmpty else { return true }
        return restrictions.allSatisfy { SkillAllowedToolPolicy.allows(toolName: toolName, declared: $0) }
    }

    public func filteredTools(
        _ tools: [InternalToolDefinition],
        runID: UUID,
        exemptToolNames: Set<String> = [SkillManager.chatToolName]
    ) -> [InternalToolDefinition] {
        tools.filter {
            isToolAllowed($0.name, runID: runID, exemptToolNames: exemptToolNames)
        }
    }
}
