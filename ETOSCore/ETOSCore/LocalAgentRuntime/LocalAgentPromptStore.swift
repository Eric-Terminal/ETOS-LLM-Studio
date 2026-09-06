// ============================================================================
// LocalAgentPromptStore.swift
// ============================================================================
// ETOS LLM Studio
//
// Agent 操作说明与用户的人设提示词分离；只有 Agent Run 会读取当前 profile。
// ============================================================================

import Foundation

public actor LocalAgentPromptStore {
    public static let shared = LocalAgentPromptStore()
    public static let builtInProfileID = UUID(uuidString: "E705A693-52C8-455C-B939-4F74F7562F4A")!

    public nonisolated static var defaultTitle: String {
        NSLocalizedString("默认本地 Agent", comment: "Default local Agent prompt profile title")
    }

    public nonisolated static var defaultContent: String {
        NSLocalizedString(
            "localLinuxRuntime.defaultInstructions",
            comment: "Default local Linux runtime instructions"
        )
    }

    public func bootstrap() {
        let profiles = Persistence.loadLocalAgentPromptProfiles()
        guard !profiles.contains(where: { $0.id == Self.builtInProfileID }) else { return }
        let profile = LocalAgentPromptProfile(
            id: Self.builtInProfileID,
            title: Self.defaultTitle,
            content: Self.defaultContent,
            isBuiltIn: true
        )
        _ = Persistence.saveLocalAgentPromptProfile(profile)
    }

    public func profiles() -> [LocalAgentPromptProfile] {
        bootstrap()
        return Persistence.loadLocalAgentPromptProfiles()
    }

    public func activeProfile() -> LocalAgentPromptProfile {
        let available = profiles().filter(\.isEnabled)
        let configuredID = AppConfigStore.textValue(for: .localLinuxActivePromptProfileID)
        if let id = UUID(uuidString: configuredID),
           let selected = available.first(where: { $0.id == id }) {
            return selected
        }
        return available.first(where: { $0.id == Self.builtInProfileID })
            ?? LocalAgentPromptProfile(
                id: Self.builtInProfileID,
                title: Self.defaultTitle,
                content: Self.defaultContent,
                isBuiltIn: true
            )
    }

    public func save(_ profile: LocalAgentPromptProfile) throws {
        guard Persistence.saveLocalAgentPromptProfile(profile) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Agent 提示词。", comment: "Save Agent prompt failure")
            )
        }
    }

    public func delete(id: UUID) throws {
        guard id != Self.builtInProfileID else { return }
        guard Persistence.deleteLocalAgentPromptProfile(id: id) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法删除 Agent 提示词。", comment: "Delete Agent prompt failure")
            )
        }
    }

    public func resetBuiltInProfile() throws -> LocalAgentPromptProfile {
        let now = Date()
        let existing = profiles().first(where: { $0.id == Self.builtInProfileID })
        let profile = LocalAgentPromptProfile(
            id: Self.builtInProfileID,
            title: Self.defaultTitle,
            content: Self.defaultContent,
            isBuiltIn: true,
            isEnabled: true,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try save(profile)
        return profile
    }
}
