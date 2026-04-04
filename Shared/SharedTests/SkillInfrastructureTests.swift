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
}
