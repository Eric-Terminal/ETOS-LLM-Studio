// ============================================================================
// OpenAIResponsesLocalShellRuntime.swift
// ETOS LLM Studio
//
// 为 OpenAI Responses 原生 local shell 物化冻结的 Skill 包，并在整个 Agent Run
// 中保持只读挂载。模型只收到 guest 路径，宿主目录不会进入请求或日志。
// ============================================================================

import Foundation

enum OpenAIResponsesLocalShellProtocol {
    static let toolName = "openai_responses_local_shell"
    static let skillsField = "openai_responses_local_shell_skills"
}

public actor OpenAIResponsesLocalShellRuntime {
    public static let shared = OpenAIResponsesLocalShellRuntime()

    private struct MountedSkill: Sendable {
        let snapshot: SkillRunSnapshot
        let guestPath: String
    }

    private struct RunEnvironment {
        let leases: [LocalLinuxMountLease]
        let skills: [MountedSkill]
    }

    private let packageStore: SkillExecutionPackageStore
    private let mountManager: LocalLinuxMountManager
    private var environments: [UUID: RunEnvironment] = [:]

    public init(
        packageStore: SkillExecutionPackageStore = .shared,
        mountManager: LocalLinuxMountManager = .shared
    ) {
        self.packageStore = packageStore
        self.mountManager = mountManager
    }

    public func toolDefinition(for context: AgentRuntimeContext) async throws -> InternalToolDefinition {
        guard let runID = context.runID else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 缺少运行标识。", comment: "Missing local Agent run identifier")
            )
        }
        let environment: RunEnvironment
        if let existing = environments[runID] {
            environment = existing
        } else {
            environment = try await prepareEnvironment(context: context)
            environments[runID] = environment
        }

        let skills: [JSONValue] = environment.skills.map { mounted in
            let trimmedDescription = mounted.snapshot.skillDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = trimmedDescription.flatMap { $0.isEmpty ? nil : $0 }
                ?? mounted.snapshot.skillName
            return .dictionary([
                "name": .string(mounted.snapshot.skillName),
                "description": .string(description),
                "path": .string(mounted.guestPath)
            ])
        }
        return InternalToolDefinition(
            name: OpenAIResponsesLocalShellProtocol.toolName,
            description: NSLocalizedString(
                "在 ETOS 隔离的本地 Linux 用户态中执行 OpenAI Responses 原生 Shell 调用。",
                comment: "OpenAI Responses local shell internal tool description"
            ),
            parameters: .dictionary([:]),
            isBlocking: true,
            kind: .openAIResponsesLocalShell,
            providerSpecificFields: [
                OpenAIResponsesLocalShellProtocol.skillsField: .array(skills)
            ]
        )
    }

    public func activateReferencedSkills(argumentsJSON: String, runID: UUID) async {
        guard let environment = environments[runID] else { return }
        for mounted in environment.skills where argumentsJSON.contains(mounted.guestPath) {
            await SkillAllowedToolRuntime.shared.activate(skill: mounted.snapshot, runID: runID)
        }
    }

    public func finishRun(id: UUID) {
        guard let environment = environments.removeValue(forKey: id) else { return }
        environment.leases.forEach { $0.release() }
    }

    private func prepareEnvironment(context: AgentRuntimeContext) async throws -> RunEnvironment {
        var leases: [LocalLinuxMountLease] = []
        var mountedSkills: [MountedSkill] = []
        do {
            for snapshot in (context.skillSnapshots ?? []).sorted(by: { $0.skillName < $1.skillName }) {
                let package = try await packageStore.materialize(
                    skillName: snapshot.skillName,
                    frozenSnapshot: snapshot
                )
                let guestPath = "/mnt/etos/skills/\(snapshot.skillID)/\(snapshot.versionDigest)"
                let lease = try await mountManager.acquireReadOnlySkillMount(
                    skillID: snapshot.skillID,
                    hostDirectory: package,
                    guestDirectory: guestPath
                )
                leases.append(lease)
                mountedSkills.append(MountedSkill(snapshot: snapshot, guestPath: guestPath))
            }
            return RunEnvironment(leases: leases, skills: mountedSkills)
        } catch {
            leases.forEach { $0.release() }
            throw error
        }
    }
}
