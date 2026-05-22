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

    @Test("frontmatter 解析支持 YAML 列表与多行文本")
    func testFrontmatterParserSupportsYAMLCollections() {
        let content = """
---
name: yaml-demo
description: >
  第一行描述
  第二行描述
when_to_use: |
  用户需要跨文件整理资料时使用。
  scripts 只能读取源码，不能执行。
compatibility:
  需要完整技能目录。
allowed-tools:
  - read_file
  - search_web
arguments: [topic, depth]
---

正文
"""

        let frontmatter = SkillFrontmatterParser.parse(content)

        #expect(frontmatter["name"] == "yaml-demo")
        #expect(frontmatter["description"] == "第一行描述 第二行描述")
        #expect(frontmatter["when_to_use"] == "用户需要跨文件整理资料时使用。\nscripts 只能读取源码，不能执行。")
        #expect(frontmatter["compatibility"] == "需要完整技能目录。")
        #expect(frontmatter["allowed-tools"] == "read_file, search_web")
        #expect(frontmatter["arguments"] == "topic, depth")
    }

    @Test("SkillManifestResolver 使用目录名和正文首段补齐缺省元数据")
    func testSkillManifestResolverUsesOfficialFallbacks() throws {
        let content = """
---
allowed-tools: read_file, search_web
when_to_use: 用户需要整理导入资料时使用。
---

# 标题不应作为描述

第一段正文会成为技能描述。
继续描述能力边界。

后续段落留给详细说明。
"""

        let manifest = try SkillManifestResolver.resolve(content: content, fallbackName: "fallback-skill")

        #expect(manifest.name == "fallback-skill")
        #expect(manifest.description.contains("第一段正文会成为技能描述。 继续描述能力边界。"))
        #expect(manifest.description.contains("用户需要整理导入资料时使用。"))
        #expect(manifest.allowedTools == ["read_file", "search_web"])
    }

    @Test("use_skill 工具描述包含元数据且会转义 XML 文本")
    func testUseSkillToolDescriptionIncludesMetadataAndEscapesXML() {
        let description = SkillManager.makeToolDescriptionForTests(availableSkills: [
            SkillMetadata(
                name: "meta-demo",
                description: "处理 <xml> & 文本",
                compatibility: "需要完整技能目录",
                allowedTools: ["read_file", "search_web"]
            )
        ])

        #expect(description.contains("<name>meta-demo</name>"))
        #expect(description.contains("<description>处理 &lt;xml&gt; &amp; 文本</description>"))
        #expect(description.contains("<compatibility>需要完整技能目录</compatibility>"))
        #expect(description.contains("<allowed_tools>read_file, search_web</allowed_tools>"))
        #expect(description.contains("allowed-tools 仅作为技能作者说明"))
    }

    @Test("SkillPaths 阻止路径穿越")
    func testSkillPathResolutionRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/skills-root-\(UUID().uuidString)", isDirectory: true)

        #expect(SkillPaths.isValidSkillName("openai-docs"))
        #expect(SkillPaths.isValidSkillName("OpenAI-Docs"))
        #expect(SkillPaths.isValidSkillName("openai_docs"))
        #expect(SkillPaths.isValidSkillName("openai.docs"))
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
        #expect(SkillResourcePolicy.candidateTextReadability(relativePath: "assets/template.unknown", size: 128).canAttemptRead)
        #expect(!SkillResourcePolicy.textReadability(relativePath: "references/large.md", size: SkillResourcePolicy.maxReadableTextBytes + 1).isReadable)
        #expect(SkillResourcePolicy.isImagePath("assets/diagram.png"))
        #expect(!SkillResourcePolicy.candidateTextReadability(relativePath: "assets/huge.png", size: SkillResourcePolicy.maxOCRImageBytes + 1).canAttemptRead)
        #if canImport(Vision) && !os(watchOS)
        #expect(SkillResourcePolicy.isOCRImagePath("assets/diagram.png"))
        #else
        #expect(!SkillResourcePolicy.isOCRImagePath("assets/diagram.png"))
        #endif
    }

    @Test("use_skill 技能名解析支持唯一宽松匹配")
    func testUseSkillNameResolutionAllowsUniqueLooseMatch() {
        let skills = [
            SkillMetadata(name: "openai-docs", description: "OpenAI 文档"),
            SkillMetadata(name: "writer.assistant", description: "写作助手"),
            SkillMetadata(name: "disabled-skill", description: "未启用")
        ]
        let enabledNames: Set<String> = ["openai-docs", "writer.assistant"]

        #expect(SkillManager.resolveSkillNameForToolCall(" openai-docs ", enabledSkillNames: enabledNames, skills: skills) == "openai-docs")
        #expect(SkillManager.resolveSkillNameForToolCall("OpenAI Docs", enabledSkillNames: enabledNames, skills: skills) == "openai-docs")
        #expect(SkillManager.resolveSkillNameForToolCall("openai_docs", enabledSkillNames: enabledNames, skills: skills) == "openai-docs")
        #expect(SkillManager.resolveSkillNameForToolCall("WRITER ASSISTANT", enabledSkillNames: enabledNames, skills: skills) == "writer.assistant")
        #expect(SkillManager.resolveSkillNameForToolCall("disabled skill", enabledSkillNames: enabledNames, skills: skills) == nil)
    }

    @Test("use_skill 技能名解析遇到歧义时不自动猜测")
    func testUseSkillNameResolutionRejectsAmbiguousLooseMatch() {
        let skills = [
            SkillMetadata(name: "foo-bar", description: "A"),
            SkillMetadata(name: "foobar", description: "B")
        ]
        let enabledNames: Set<String> = ["foo-bar", "foobar"]

        #expect(SkillManager.resolveSkillNameForToolCall("foo bar", enabledSkillNames: enabledNames, skills: skills) == nil)
        #expect(SkillManager.resolveSkillNameForToolCall("foobar", enabledSkillNames: enabledNames, skills: skills) == "foobar")
    }

    @Test("use_skill action 参数解析支持常见写法")
    func testUseSkillActionResolutionAllowsCommonVariants() {
        #expect(SkillManager.SkillToolAction.resolveToolArgument("read_instructions") == .readInstructions)
        #expect(SkillManager.SkillToolAction.resolveToolArgument("instructions") == .readInstructions)
        #expect(SkillManager.SkillToolAction.resolveToolArgument("readInstructions") == .readInstructions)
        #expect(SkillManager.SkillToolAction.resolveToolArgument("list resources") == .listResources)
        #expect(SkillManager.SkillToolAction.resolveToolArgument("list-resources") == .listResources)
        #expect(SkillManager.SkillToolAction.resolveToolArgument("read resource") == .readResource)
        #expect(SkillManager.SkillToolAction.resolveToolArgument("read-resource") == .readResource)
        #expect(SkillManager.SkillToolAction.resolveToolArgument("run_script") == nil)
    }

    @MainActor
    @Test("use_skill 工具 schema 限定当前启用技能名")
    func testUseSkillToolSchemaIncludesEnabledSkillNameEnum() {
        let manager = SkillManager.shared
        let originalEnabled = manager.enabledSkillNames
        let originalSwitch = manager.chatToolsEnabled
        let enabledSkillName = "schema-enabled-\(UUID().uuidString.lowercased())"
        let disabledSkillName = "schema-disabled-\(UUID().uuidString.lowercased())"
        defer {
            _ = manager.deleteSkill(enabledSkillName)
            _ = manager.deleteSkill(disabledSkillName)
            manager.restoreStateForTests(
                chatToolsEnabled: originalSwitch,
                enabledSkillNames: originalEnabled
            )
        }

        #expect(manager.saveSkillDataFilesAtomically(skillName: enabledSkillName, files: [
            "SKILL.md": Data("""
            ---
            name: \(enabledSkillName)
            description: "启用技能"
            ---

            正文
            """.utf8)
        ]))
        #expect(manager.saveSkillDataFilesAtomically(skillName: disabledSkillName, files: [
            "SKILL.md": Data("""
            ---
            name: \(disabledSkillName)
            description: "停用技能"
            ---

            正文
            """.utf8)
        ]))
        manager.restoreStateForTests(chatToolsEnabled: true, enabledSkillNames: [enabledSkillName])

        let tool = manager.chatToolsForLLM().first
        guard case let .dictionary(parameters)? = tool?.parameters,
              case let .dictionary(properties)? = parameters["properties"],
              case let .dictionary(nameSchema)? = properties["name"],
              case let .array(nameEnum)? = nameSchema["enum"] else {
            Issue.record("use_skill 工具缺少 name enum schema")
            return
        }

        #expect(nameEnum.contains(.string(enabledSkillName)))
        #expect(!nameEnum.contains(.string(disabledSkillName)))
    }

    @Test("GitHub 技能导入支持 tree、blob 与 raw 链接解析")
    func testGitHubSkillImporterParsesCommonURLs() {
        #expect(SkillGitHubImporter.parseGitHubURL("https://github.com/acme/skills") == SkillGitHubImporter.GitHubRepoInfo(owner: "acme", repo: "skills", branch: "HEAD", path: ""))
        #expect(SkillGitHubImporter.parseGitHubURL("https://github.com/acme/skills/tree/main/.claude/skills/demo") == SkillGitHubImporter.GitHubRepoInfo(owner: "acme", repo: "skills", branch: "main", path: ".claude/skills/demo"))
        #expect(SkillGitHubImporter.parseGitHubURL("https://github.com/acme/skills/blob/main/.claude/skills/demo/SKILL.md") == SkillGitHubImporter.GitHubRepoInfo(owner: "acme", repo: "skills", branch: "main", path: ".claude/skills/demo"))
        #expect(SkillGitHubImporter.parseGitHubURL("https://raw.githubusercontent.com/acme/skills/main/.claude/skills/demo/SKILL.md") == SkillGitHubImporter.GitHubRepoInfo(owner: "acme", repo: "skills", branch: "main", path: ".claude/skills/demo"))
    }

    @Test("GitHub 技能导入会展开唯一嵌套技能目录")
    func testGitHubSkillImporterSelectsSingleNestedSkillDirectory() throws {
        let files = [
            SkillGitHubImporter.GitHubListedFile(relativePath: ".claude/skills/demo/SKILL.md", downloadURL: "https://example.com/SKILL.md"),
            SkillGitHubImporter.GitHubListedFile(relativePath: ".claude/skills/demo/references/guide.md", downloadURL: "https://example.com/guide.md"),
            SkillGitHubImporter.GitHubListedFile(relativePath: "README.md", downloadURL: "https://example.com/README.md")
        ]

        let selected = try SkillGitHubImporter.selectedFilesForImport(files)

        #expect(selected.fallbackName == "demo")
        #expect(selected.files.map(\.relativePath).sorted() == ["SKILL.md", "references/guide.md"])
    }

    @Test("GitHub 技能导入遇到多个嵌套技能时要求用户选择具体目录")
    func testGitHubSkillImporterRejectsMultipleNestedSkills() throws {
        let files = [
            SkillGitHubImporter.GitHubListedFile(relativePath: ".claude/skills/a/SKILL.md", downloadURL: "https://example.com/a.md"),
            SkillGitHubImporter.GitHubListedFile(relativePath: ".claude/skills/b/SKILL.md", downloadURL: "https://example.com/b.md")
        ]

        #expect(throws: SkillStoreError.self) {
            _ = try SkillGitHubImporter.selectedFilesForImport(files)
        }
    }

    @Test("GitHub 根目录技能会保留文件并等待仓库名兜底")
    func testGitHubSkillImporterSelectsRootSkillDirectory() throws {
        let files = [
            SkillGitHubImporter.GitHubListedFile(relativePath: "SKILL.md", downloadURL: "https://example.com/SKILL.md"),
            SkillGitHubImporter.GitHubListedFile(relativePath: "references/guide.md", downloadURL: "https://example.com/guide.md")
        ]

        let selected = try SkillGitHubImporter.selectedFilesForImport(files)

        #expect(selected.fallbackName == nil)
        #expect(selected.files.map(\.relativePath).sorted() == ["SKILL.md", "references/guide.md"])
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
            "references/FORM": Data("无扩展名表单".utf8),
            "assets/template.custom": Data("未知扩展文本模板".utf8),
            "scripts/check.py": Data("print('只读脚本')".utf8),
            "agents/openai.yaml": Data("interface:\n  display_name: Resource Test".utf8),
            "assets/blank.png": pngFixture,
            "assets/blob.png": Data([0x89, 0x50, 0x4E, 0x47, 0x00])
        ]
        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: files))
        manager.restoreStateForTests(chatToolsEnabled: true, enabledSkillNames: [skillName])

        let listResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"list resources"}"#
        )
        #expect(listResult.contains("references/guide.md"))
        #expect(listResult.contains("references/FORM"))
        #expect(listResult.contains("assets/template.custom"))
        #expect(listResult.contains("scripts/check.py"))
        #expect(listResult.contains("assets/blank.png"))
        #expect(listResult.contains("assets/blob.png"))
        #expect(listResult.contains("不会执行"))
        let listedFiles = manager.listFiles(skillName: skillName)
        #expect(listedFiles.first(where: { $0.relativePath == "references/FORM" })?.isReadableText == true)
        #expect(listedFiles.first(where: { $0.relativePath == "assets/template.custom" })?.isReadableText == true)
        #if canImport(Vision) && !os(watchOS)
        #expect(listedFiles.first(where: { $0.relativePath == "assets/blank.png" })?.isReadableText == true)
        #else
        #expect(listedFiles.first(where: { $0.relativePath == "assets/blank.png" })?.isReadableText == false)
        #endif
        #expect(listedFiles.first(where: { $0.relativePath == "assets/blob.png" })?.isReadableText == false)

        let referenceResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read resource","path":"references/guide.md"}"#
        )
        #expect(referenceResult.contains("参考资料正文"))

        let extensionlessResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"references/FORM"}"#
        )
        #expect(extensionlessResult.contains("无扩展名表单"))

        let customExtensionResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"assets/template.custom"}"#
        )
        #expect(customExtensionResult.contains("未知扩展文本模板"))

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
        #if canImport(Vision) && !os(watchOS)
        await #expect(throws: SkillStoreError.self) {
            _ = try await manager.executeToolFromChat(
                toolName: SkillManager.chatToolName,
                argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"assets/blank.png"}"#
            )
        }
        #endif

        let bundle = SyncedSkillBundle(
            name: skillName,
            files: files.map { SyncedSkillFile(relativePath: $0.key, data: $0.value) }
        )
        #expect(bundle.files.first(where: { $0.relativePath == "assets/blob.png" })?.fileData == files["assets/blob.png"])
    }

    @MainActor
    @Test("use_skill 支持分块读取大文本资源")
    func testUseSkillReadsLargeTextResourcesByLineChunk() async throws {
        let manager = SkillManager.shared
        let originalEnabled = manager.enabledSkillNames
        let originalSwitch = manager.chatToolsEnabled
        let skillName = "large-resource-\(UUID().uuidString.lowercased())"
        defer {
            _ = manager.deleteSkill(skillName)
            manager.restoreStateForTests(
                chatToolsEnabled: originalSwitch,
                enabledSkillNames: originalEnabled
            )
        }

        let largeText = (1...1200)
            .map { "line\($0) " + String(repeating: "x", count: 256) }
            .joined(separator: "\n")
        #expect(Data(largeText.utf8).count > SkillResourcePolicy.maxReadableTextBytes)
        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: [
            "SKILL.md": Data("""
            ---
            name: \(skillName)
            description: "大文本分块读取测试"
            ---

            正文
            """.utf8),
            "references/large.md": Data(largeText.utf8)
        ]))
        manager.restoreStateForTests(chatToolsEnabled: true, enabledSkillNames: [skillName])

        let chunkResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"references/large.md","start_line":1001,"max_lines":3}"#
        )

        #expect(chunkResult.contains("第 1001-1003 行"))
        #expect(chunkResult.contains("还有更多"))
        #expect(chunkResult.contains("line1001 "))
        #expect(chunkResult.contains("line1002 "))
        #expect(chunkResult.contains("line1003 "))

        await #expect(throws: SkillStoreError.self) {
            _ = try await manager.executeToolFromChat(
                toolName: SkillManager.chatToolName,
                argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"references/large.md"}"#
            )
        }
    }

    @MainActor
    @Test("use_skill 可抽取技能包文档资源文本")
    func testUseSkillExtractsDocumentResources() async throws {
        let manager = SkillManager.shared
        let originalEnabled = manager.enabledSkillNames
        let originalSwitch = manager.chatToolsEnabled
        let skillName = "document-resource-\(UUID().uuidString.lowercased())"
        defer {
            _ = manager.deleteSkill(skillName)
            manager.restoreStateForTests(
                chatToolsEnabled: originalSwitch,
                enabledSkillNames: originalEnabled
            )
        }

        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: [
            "SKILL.md": Data("""
            ---
            name: \(skillName)
            description: "文档资源读取测试"
            ---

            正文
            """.utf8),
            "references/guide.docx": try FileAttachmentTextFixtureFactory.makeDOCXFixture()
        ]))
        manager.restoreStateForTests(chatToolsEnabled: true, enabledSkillNames: [skillName])

        let listResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"list_resources"}"#
        )
        #expect(listResult.contains("references/guide.docx"))
        #expect(listResult.contains("可读取"))

        let fullResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"references/guide.docx"}"#
        )
        #expect(fullResult.contains("DOCX 第一段"))
        #expect(fullResult.contains("DOCX 第二段"))

        let chunkResult = try await manager.executeToolFromChat(
            toolName: SkillManager.chatToolName,
            argumentsJSON: #"{"name":"\#(skillName)","action":"read_resource","path":"references/guide.docx","start_line":1,"max_lines":1}"#
        )
        #expect(chunkResult.contains("第 1-1 行"))
        #expect(chunkResult.contains("DOCX 第一段"))
    }

    @MainActor
    @Test("保存技能包时允许 SKILL.md 省略 name 和 description")
    func testSkillStoreAcceptsMissingOptionalManifestFields() throws {
        let manager = SkillManager.shared
        let originalEnabled = manager.enabledSkillNames
        let originalSwitch = manager.chatToolsEnabled
        let skillName = "manifest-fallback-\(UUID().uuidString.lowercased())"
        defer {
            _ = manager.deleteSkill(skillName)
            manager.restoreStateForTests(
                chatToolsEnabled: originalSwitch,
                enabledSkillNames: originalEnabled
            )
        }

        #expect(manager.saveSkillDataFilesAtomically(skillName: skillName, files: [
            "SKILL.md": Data("""
            ---
            ---

            这一段来自正文，会变成技能描述。
            """.utf8)
        ]))

        let saved = try #require(manager.skills.first(where: { $0.name == skillName }))
        #expect(saved.description == "这一段来自正文，会变成技能描述。")
    }

    @Test("SkillBundleImporter 用建议文件名补齐单文件下载技能名")
    func testSkillBundleImporterUsesSuggestedFileNameFallback() throws {
        let result = try SkillBundleImporter.importSkill(
            fromDownloadedData: Data("""
            ---
            description: "单文件下载技能"
            ---

            正文
            """.utf8),
            suggestedFileName: "download-demo.md"
        )

        #expect(result.skillName == "download-demo")
    }

    @Test("SkillBundleImporter 支持隐藏外层目录里的技能包")
    func testSkillBundleImporterReadsSkillUnderHiddenParentDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("skill-hidden-root-\(UUID().uuidString)", isDirectory: true)
        let skillDir = root
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("hidden-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("references", isDirectory: true), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try Data("""
        ---
        description: "隐藏目录技能"
        ---

        正文
        """.utf8).write(to: skillDir.appendingPathComponent("SKILL.md"))
        try Data("隐藏目录参考资料".utf8).write(to: skillDir.appendingPathComponent("references", isDirectory: true).appendingPathComponent("guide.md"))

        let result = try SkillBundleImporter.importSkill(from: root)

        #expect(result.skillName == "hidden-demo")
        #expect(String(data: result.files["SKILL.md"] ?? Data(), encoding: .utf8)?.contains("隐藏目录技能") == true)
        #expect(String(data: result.files["references/guide.md"] ?? Data(), encoding: .utf8) == "隐藏目录参考资料")
        #expect(result.files.keys.allSatisfy { !$0.hasPrefix(".claude/") })
    }

    @Test("SkillBundleImporter 支持带顶层目录的 zip 技能包")
    func testSkillBundleImporterReadsZipBundleWithRootDirectory() throws {
        let result = try SkillBundleImporter.importSkill(
            fromDownloadedData: try #require(Data(base64Encoded: zipBundleBase64)),
            suggestedFileName: nil
        )

        #expect(result.skillName == "zip-demo")
        #expect(String(data: result.files["SKILL.md"] ?? Data(), encoding: .utf8)?.contains("zip demo") == true)
        #expect(String(data: result.files["references/guide.md"] ?? Data(), encoding: .utf8) == zipReferenceContent)
        #expect(result.files["assets/blob.png"] == zipBinaryContent)
        #expect(result.files.keys.allSatisfy { !$0.hasPrefix("demo-skill/") })
    }

    private var zipReferenceContent: String {
        "zip 参考资料"
    }

    private var zipBinaryContent: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x00])
    }

    private var pngFixture: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()
    }

    private var zipBundleBase64: String {
        "UEsDBBQAAAAIAGiTtlwK+ZucSwAAAE0AAAATAAAAZGVtby1za2lsbC9TS0lMTC5tZNPV1eXKS8xNtVKoyizQTUnNzedKSS1OLsosKMnMz7NSUAIKK4CElbh0gUq5nuzd/3zKCoWi1LTUotS85NRi/fTSzJRUvdyUxw1NAFBLAwQUAAAACABok7ZcDkdrVBMAAAAQAAAAHgAAAGRlbW8tc2tpbGwvcmVmZXJlbmNlcy9ndWlkZS5tZKvKLFB42t/0oqH5xdaWZ9NmAgBQSwMEFAAAAAgAaJO2XFRT5XQHAAAABQAAABoAAABkZW1vLXNraWxsL2Fzc2V0cy9ibG9iLnBuZ+sM8HNnAABQSwECFAMUAAAACABok7ZcCvmbnEsAAABNAAAAEwAAAAAAAAAAAAAAgAEAAAAAZGVtby1za2lsbC9TS0lMTC5tZFBLAQIUAxQAAAAIAGiTtlwOR2tUEwAAABAAAAAeAAAAAAAAAAAAAACAAXwAAABkZW1vLXNraWxsL3JlZmVyZW5jZXMvZ3VpZGUubWRQSwECFAMUAAAACABok7ZcVFPldAcAAAAFAAAAGgAAAAAAAAAAAAAAgAHLAAAAZGVtby1za2lsbC9hc3NldHMvYmxvYi5wbmdQSwUGAAAAAAMAAwDVAAAACgEAAAAA"
    }
}
