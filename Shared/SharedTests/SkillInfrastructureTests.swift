// ============================================================================
// SkillInfrastructureTests.swift
// ============================================================================
// Agent Skills 基础能力测试
// - frontmatter 解析
// - 路径安全
// - 同步模型兼容性
// - use_skill 链接白名单策略
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("Agent Skills 基础能力测试")
struct SkillInfrastructureTests {

    @Test("frontmatter 解析与正文提取支持 Unicode")
    func testFrontmatterParserSupportsUnicode() {
        let content = """
---
name: 智能✨技能
description: "用于处理中文🙂"
compatibility: "v1"
allowed-tools: read_file, search_web
---

第一行正文
第二行正文
"""

        let frontmatter = SkillFrontmatterParser.parse(content)
        #expect(frontmatter["name"] == "智能✨技能")
        #expect(frontmatter["description"] == "用于处理中文🙂")
        #expect(frontmatter["compatibility"] == "v1")
        #expect(frontmatter["allowed-tools"] == "read_file, search_web")

        let body = SkillFrontmatterParser.extractBody(content)
        #expect(body == "第一行正文\n第二行正文")
    }

    @Test("SkillPaths 阻止路径穿越")
    func testSkillPathResolutionRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/skills-root-\(UUID().uuidString)", isDirectory: true)

        #expect(SkillPaths.isValidSkillName("openai-docs"))
        #expect(!SkillPaths.isValidSkillName("../openai-docs"))
        #expect(!SkillPaths.isValidSkillName(""))

        let dir = SkillPaths.resolveSkillDir(skillsRoot: root, skillName: "openai-docs")
        #expect(dir != nil)

        if let dir {
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "refs/checklist.md") != nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "../etc/passwd") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "/absolute/path.md") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "refs//guide.md") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "refs/.hidden.md") == nil)
            #expect(SkillPaths.resolveSkillFile(skillDir: dir, relativePath: "") == nil)
        }
    }

    @Test("SyncedSkillBundle 校验和与文件顺序无关")
    func testSyncedSkillBundleChecksumIsOrderIndependent() {
        let filesA = [
            SyncedSkillFile(relativePath: "SKILL.md", content: "A"),
            SyncedSkillFile(relativePath: "refs/a.md", content: "B")
        ]
        let filesB = [
            SyncedSkillFile(relativePath: "refs/a.md", content: "B"),
            SyncedSkillFile(relativePath: "SKILL.md", content: "A")
        ]

        let bundleA = SyncedSkillBundle(name: "demo", files: filesA)
        let bundleB = SyncedSkillBundle(name: "demo", files: filesB)
        #expect(bundleA.checksum == bundleB.checksum)

        let changed = SyncedSkillBundle(
            name: "demo",
            files: [
                SyncedSkillFile(relativePath: "SKILL.md", content: "A"),
                SyncedSkillFile(relativePath: "refs/a.md", content: "Changed")
            ]
        )
        #expect(bundleA.checksum != changed.checksum)
    }

    @Test("SyncPackage 兼容旧数据：缺失 skills 字段时默认为空")
    func testSyncPackageDecodingDefaultsMissingSkills() throws {
        let legacyJSON = """
{
  "options": 0,
  "providers": [],
  "sessions": []
}
"""

        let package = try JSONDecoder().decode(SyncPackage.self, from: Data(legacyJSON.utf8))
        #expect(package.skills.isEmpty)
    }

    @Test("use_skill 仅允许 SKILL.md 中声明的相对链接路径")
    func testSkillLinkedPathPolicyExtractsMarkdownLinks() {
        let content = """
---
name: demo
description: "demo"
---

[清单](refs/checklist.md)
[带锚点](./refs/guide.md#part)
[带查询](refs/query.md?lang=zh)
[外链](https://example.com/docs)
[纯锚点](#section)
![图片](assets/diagram.png)
[引用式][ref_doc]

[ref_doc]: refs/reference.md
"""

        let paths = SkillLinkedPathPolicy.extractLinkedRelativePaths(from: content)

        #expect(paths.contains("refs/checklist.md"))
        #expect(paths.contains("refs/guide.md"))
        #expect(paths.contains("refs/query.md"))
        #expect(paths.contains("assets/diagram.png"))
        #expect(paths.contains("refs/reference.md"))
        #expect(!paths.contains("https://example.com/docs"))
        #expect(!paths.contains("#section"))
    }

    @Test("use_skill 路径规范化会过滤非法输入")
    func testSkillLinkedPathPolicyNormalize() {
        #expect(SkillLinkedPathPolicy.normalizeRelativePath("./refs/guide.md#intro") == "refs/guide.md")
        #expect(SkillLinkedPathPolicy.normalizeRelativePath("refs/checklist.md?x=1") == "refs/checklist.md")
        #expect(SkillLinkedPathPolicy.normalizeRelativePath("<refs/a.md>") == "refs/a.md")
        #expect(SkillLinkedPathPolicy.normalizeRelativePath("#only-anchor") == nil)
        #expect(SkillLinkedPathPolicy.normalizeRelativePath("https://example.com/a.md") == nil)
        #expect(SkillLinkedPathPolicy.normalizeRelativePath("../escape.md") == nil)
        #expect(SkillLinkedPathPolicy.normalizeRelativePath("") == nil)
    }

    @Test("SkillResourcePolicy 允许读取技能包文本资源并拒绝危险路径")
    func testSkillResourcePolicyReadability() {
        #expect(SkillResourcePolicy.normalizeRelativePath("./references/guide.md#intro") == "references/guide.md")
        #expect(SkillResourcePolicy.normalizeRelativePath("scripts/run.py") == "scripts/run.py")
        #expect(SkillResourcePolicy.normalizeRelativePath("agents/openai.yaml") == "agents/openai.yaml")
        #expect(SkillResourcePolicy.normalizeRelativePath("assets/template.json") == "assets/template.json")
        #expect(SkillResourcePolicy.normalizeRelativePath(".secret/token.txt") == nil)
        #expect(SkillResourcePolicy.normalizeRelativePath("references//guide.md") == nil)
        #expect(SkillResourcePolicy.normalizeRelativePath("references/../secret.md") == nil)
        #expect(SkillResourcePolicy.normalizeRelativePath("https://example.com/a.md") == nil)

        #expect(SkillResourcePolicy.textReadability(relativePath: "scripts/run.py", size: 128).isReadable)
        #expect(SkillResourcePolicy.textReadability(relativePath: "references/guide.md", size: 128).isReadable)
        #expect(!SkillResourcePolicy.textReadability(relativePath: "assets/icon.png", size: 128).isReadable)
        #expect(!SkillResourcePolicy.textReadability(relativePath: "references/large.md", size: SkillResourcePolicy.maxReadableTextBytes + 1).isReadable)
    }

    @MainActor
    @Test("use_skill 可列出并读取技能包文本资源但不读取二进制资源")
    func testUseSkillReadsBundledTextResources() async throws {
        let manager = SkillManager.shared
        let originalEnabled = manager.enabledSkillNames
        let originalSwitch = manager.chatToolsEnabled
        let skillName = "resource-test-\(UUID().uuidString.lowercased())"
        defer {
            _ = manager.deleteSkill(skillName)
            manager.restoreStateForTests(
                chatToolsEnabled: originalSwitch,
                enabledSkillNames: originalEnabled
            )
        }

        let files = [
            "SKILL.md": Data("""
            ---
            name: \(skillName)
            description: "资源读取测试"
            ---

            先读取正文，再按需查看资源。
            """.utf8),
            "references/guide.md": Data("参考资料正文".utf8),
            "scripts/check.py": Data("print('只读脚本')".utf8),
            "agents/openai.yaml": Data("interface:\n  display_name: Resource Test".utf8),
            "assets/blob.png": Data([0x89, 0x50, 0x4E, 0x47, 0x00])
        ]
        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: files))
        manager.restoreStateForTests(chatToolsEnabled: true, enabledSkillNames: [skillName])

        let listResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"list_resources"}"#
        )
        #expect(listResult.contains("references/guide.md"))
        #expect(listResult.contains("scripts/check.py"))
        #expect(listResult.contains("assets/blob.png"))
        #expect(listResult.contains("不会执行"))
        let listedFiles = manager.listFiles(skillName: skillName)
        #expect(listedFiles.first(where: { $0.relativePath == "assets/blob.png" })?.isReadableText == false)

        let referenceResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"references/guide.md"}"#
        )
        #expect(referenceResult.contains("参考资料正文"))

        let scriptResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"scripts/check.py"}"#
        )
        #expect(scriptResult.contains("print('只读脚本')"))

        await #expect(throws: SkillStoreError.self) {
            _ = try await manager.executeToolFromChat(
                toolName: SkillManager.chatToolName,
                argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"assets/blob.png"}"#
            )
        }

        let bundle = SyncedSkillBundle(
            name: skillName,
            files: files.map { SyncedSkillFile(relativePath: $0.key, data: $0.value) }
        )
        #expect(bundle.files.first(where: { $0.relativePath == "assets/blob.png" })?.fileData == files["assets/blob.png"])
    }
}
