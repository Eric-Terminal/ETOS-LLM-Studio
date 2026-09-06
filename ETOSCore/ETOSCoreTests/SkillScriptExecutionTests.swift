// ============================================================================
// SkillScriptExecutionTests.swift
// ETOS LLM Studio
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Agent Skill 脚本执行安全测试")
struct SkillScriptExecutionTests {
    @MainActor
    @Test("脚本解析支持 sh、Python、Node、shebang 与 AArch64 ELF")
    func resolvesSupportedScriptKinds() throws {
        let manager = SkillManager.shared
        let skillName = "script-kinds-\(UUID().uuidString.lowercased())"
        defer { _ = manager.deleteSkill(skillName) }

        var binary = Data(repeating: 0, count: 64)
        binary[0] = 0x7f
        binary[1] = 0x45
        binary[2] = 0x4c
        binary[3] = 0x46
        binary[4] = 2
        binary[5] = 1
        binary[18] = 183
        binary[19] = 0
        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: [
            "SKILL.md": manifest(name: skillName),
            "scripts/check.sh": Data("printf '%s\\n' ok".utf8),
            "scripts/check.py": Data("print('ok')".utf8),
            "scripts/check.mjs": Data("console.log('ok')".utf8),
            "scripts/direct": Data("#!/bin/sh\nprintf '%s\\n' direct".utf8),
            "scripts/tool": binary
        ]))
        let directURL = try #require(SkillStore.resolveSkillFile(skillName: skillName, relativePath: "scripts/direct"))
        let binaryURL = try #require(SkillStore.resolveSkillFile(skillName: skillName, relativePath: "scripts/tool"))
        #expect(try isExecutable(directURL))
        #expect(try isExecutable(binaryURL))
        let metadata = try #require(manager.skills.first { $0.name == skillName })
        let snapshot = try SkillRunSnapshotBuilder.build(skill: metadata)

        let shell = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "scripts/check.sh", frozenSnapshot: snapshot)
        #expect(shell.executable == "/bin/sh")
        #expect(shell.argumentsPrefix == ["/mnt/etos/skills/\(skillName)/scripts/check.sh"])
        let python = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "scripts/check.py", frozenSnapshot: snapshot)
        #expect(python.executable == "python3")
        let node = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "scripts/check.mjs", frozenSnapshot: snapshot)
        #expect(node.executable == "node")
        let shebang = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "scripts/direct", frozenSnapshot: snapshot)
        #expect(shebang.executable == "/mnt/etos/skills/\(skillName)/scripts/direct")
        #expect(shebang.requiredInterpreter == "/bin/sh")
        let executable = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "scripts/tool", frozenSnapshot: snapshot)
        #expect(executable.executable.hasSuffix("/scripts/tool"))
        #expect(executable.requiredInterpreter == nil)
    }

    @MainActor
    @Test("脚本解析拒绝目录穿越、非 scripts 文件与符号链接逃逸")
    func rejectsEscapingPaths() throws {
        let manager = SkillManager.shared
        let skillName = "script-paths-\(UUID().uuidString.lowercased())"
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).sh")
        defer {
            _ = manager.deleteSkill(skillName)
            try? FileManager.default.removeItem(at: outside)
        }
        try "echo outside".write(to: outside, atomically: true, encoding: .utf8)
        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: [
            "SKILL.md": manifest(name: skillName),
            "references/check.sh": Data("echo reference".utf8),
            "scripts/check.sh": Data("echo safe".utf8)
        ]))
        let metadata = try #require(manager.skills.first { $0.name == skillName })
        let snapshot = try SkillRunSnapshotBuilder.build(skill: metadata)

        #expect(throws: SkillExecutionError.self) {
            _ = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "../scripts/check.sh", frozenSnapshot: snapshot)
        }
        #expect(throws: SkillExecutionError.self) {
            _ = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "references/check.sh", frozenSnapshot: snapshot)
        }

        let scriptURL = try #require(SkillStore.resolveSkillFile(skillName: skillName, relativePath: "scripts/check.sh"))
        try FileManager.default.removeItem(at: scriptURL)
        try FileManager.default.createSymbolicLink(at: scriptURL, withDestinationURL: outside)
        #expect(throws: SkillExecutionError.self) {
            _ = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "scripts/check.sh", frozenSnapshot: snapshot)
        }
    }

    @MainActor
    @Test("Skill 或脚本更新后冻结授权立即失效")
    func rejectsStaleSnapshot() throws {
        let manager = SkillManager.shared
        let skillName = "script-stale-\(UUID().uuidString.lowercased())"
        defer { _ = manager.deleteSkill(skillName) }
        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: [
            "SKILL.md": manifest(name: skillName),
            "scripts/check.py": Data("print('v1')".utf8)
        ]))
        let metadata = try #require(manager.skills.first { $0.name == skillName })
        let snapshot = try SkillRunSnapshotBuilder.build(skill: metadata)
        #expect(manager.saveSkillFile(skillName: skillName, relativePath: "scripts/check.py", content: "print('v2')"))

        #expect(throws: SkillExecutionError.self) {
            _ = try SkillScriptResolver.resolve(skillName: skillName, relativePath: "scripts/check.py", frozenSnapshot: snapshot)
        }
    }

    @Test("allowed-tools 只能收窄会话现有工具")
    func allowedToolsCannotExpandSessionCapabilities() {
        let enabled: Set<String> = ["read_file", "search_web"]
        #expect(SkillAllowedToolPolicy.effectiveTools(declared: [], sessionEnabled: enabled) == enabled)
        #expect(
            SkillAllowedToolPolicy.effectiveTools(
                declared: ["search_web", "linux_shell", "unknown_tool"],
                sessionEnabled: enabled
            ) == ["search_web"]
        )
        #expect(SkillAllowedToolPolicy.allows(toolName: "mcp://server/search_web", declared: ["search_web"]))
        #expect(SkillAllowedToolPolicy.allows(toolName: "mcp_search_web", declared: ["search_web"]))
        #expect(!SkillAllowedToolPolicy.allows(toolName: "mcp_delete_search_web", declared: ["search_web"]))
        #expect(!SkillAllowedToolPolicy.allows(toolName: "linux_shell", declared: ["search_web"]))
    }

    @Test("加载 Skill 后 allowed-tools 会过滤工具并在 Run 结束时释放")
    func allowedToolsAreEnforcedForActiveRun() async {
        let runtime = SkillAllowedToolRuntime()
        let runID = UUID()
        let snapshot = SkillRunSnapshot(
            skillID: "restricted",
            skillName: "restricted",
            versionDigest: String(repeating: "a", count: 64),
            allowedTools: ["search_web"],
            scripts: []
        )
        let tools = [
            InternalToolDefinition(name: "search_web", description: "", parameters: .dictionary([:])),
            InternalToolDefinition(name: "linux_shell", description: "", parameters: .dictionary([:])),
            InternalToolDefinition(name: SkillManager.chatToolName, description: "", parameters: .dictionary([:]))
        ]

        await runtime.activate(skill: snapshot, runID: runID)
        let filtered = await runtime.filteredTools(tools, runID: runID)
        let deniedBeforeFinish = await runtime.isToolAllowed("linux_shell", runID: runID)
        #expect(Set(filtered.map(\.name)) == ["search_web", SkillManager.chatToolName])
        #expect(!deniedBeforeFinish)

        await runtime.finishRun(id: runID)
        let allowedAfterFinish = await runtime.isToolAllowed("linux_shell", runID: runID)
        #expect(allowedAfterFinish)
    }

    @Test("当前版本授权与冻结摘要不一致时会失效")
    func currentVersionApprovalRequiresExactDigest() {
        let record = SkillExecutionPolicyRecord(
            skillName: "demo",
            policy: .allowCurrentVersion,
            approvedVersionDigest: "version-a"
        )
        #expect(
            SkillExecutionPolicyStatus(record: record, currentVersionDigest: "version-a")
                .isCurrentVersionApproved
        )
        #expect(
            !SkillExecutionPolicyStatus(record: record, currentVersionDigest: "version-b")
                .isCurrentVersionApproved
        )
    }

    @Test("缺失解释器诊断可关联用户主动安装配方")
    func missingInterpreterRecipeLookup() {
        #expect(LocalLinuxEnvironmentRecipes.matching(command: "python3")?.id == "python")
        #expect(LocalLinuxEnvironmentRecipes.matching(command: "/usr/bin/node")?.id == "node")
        #expect(LocalLinuxEnvironmentRecipes.matching(command: "custom-runtime") == nil)
    }

    @MainActor
    @Test("execute_script 缺少可信 Agent 归属时不会进入运行时")
    func executeScriptRequiresTrustedAgentContext() async throws {
        let manager = SkillManager.shared
        let originalEnabled = manager.enabledSkillNames
        let originalSwitch = manager.chatToolsEnabled
        let skillName = "script-context-\(UUID().uuidString.lowercased())"
        defer {
            _ = manager.deleteSkill(skillName)
            manager.restoreStateForTests(chatToolsEnabled: originalSwitch, enabledSkillNames: originalEnabled)
        }
        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: [
            "SKILL.md": manifest(name: skillName),
            "scripts/check.sh": Data("echo safe".utf8)
        ]))
        manager.restoreStateForTests(chatToolsEnabled: true, enabledSkillNames: [skillName])

        await #expect(throws: SkillExecutionError.self) {
            _ = try await manager.executeToolFromChat(
                toolName: SkillManager.chatToolName,
                argumentsJSON: #"{"name":"\#(skillName)","action":"execute_script","path":"scripts/check.sh"}"#
            )
        }
    }

    private func manifest(name: String) -> Data {
        Data("""
        ---
        name: \(name)
        description: "脚本执行测试"
        ---

        仅用于验证脚本边界。
        """.utf8)
    }

    private func isExecutable(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return permissions & 0o111 != 0
    }
}
