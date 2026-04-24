// ============================================================================
// SkillManager.swift
// ============================================================================
// Agent Skills 管理器
// - 负责技能列表与启用状态
// - 负责聊天工具暴露与执行
// - 提供 GitHub 导入入口
// ============================================================================

import Foundation
import Combine
import os.log

@MainActor
public final class SkillManager: ObservableObject {
    public static let shared = SkillManager()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则技能列表与开关状态不会稳定刷新。

    public nonisolated static let chatToolName = "use_skill"

    private enum DefaultsKey {
        static let enabledSkillNames = "skills.enabledNames"
        static let chatToolsEnabled = "skills.chatToolsEnabled"
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SkillManager")
    private let defaults: UserDefaults

    @Published public private(set) var skills: [SkillMetadata] = []
    @Published public private(set) var enabledSkillNames: Set<String>
    @Published public private(set) var chatToolsEnabled: Bool
    @Published public private(set) var lastErrorMessage: String?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabledSkillNames = Set(defaults.stringArray(forKey: DefaultsKey.enabledSkillNames) ?? [])
        self.chatToolsEnabled = defaults.object(forKey: DefaultsKey.chatToolsEnabled) as? Bool ?? true
        reloadFromDisk()
    }

    public nonisolated static func isSkillToolName(_ name: String) -> Bool {
        name == chatToolName
    }

    public func reloadFromDisk() {
        skills = SkillStore.listSkills()
        pruneMissingEnabledSkills()
    }

    public func setChatToolsEnabled(_ isEnabled: Bool) {
        guard chatToolsEnabled != isEnabled else { return }
        chatToolsEnabled = isEnabled
        defaults.set(isEnabled, forKey: DefaultsKey.chatToolsEnabled)
        logger.info("Agent Skills 聊天工具总开关已\(isEnabled ? "开启" : "关闭")。")
    }

    public func setSkillEnabled(name: String, isEnabled: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isEnabled {
            enabledSkillNames.insert(trimmed)
        } else {
            enabledSkillNames.remove(trimmed)
        }
        persistEnabledSkillNames()
    }

    public func isSkillEnabled(_ name: String) -> Bool {
        enabledSkillNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    public func saveSkillFromContent(_ content: String) -> Bool {
        let frontmatter = SkillFrontmatterParser.parse(content)
        guard let name = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            lastErrorMessage = "SKILL.md 缺少 name 字段。"
            return false
        }
        return saveSkill(name: name, content: content)
    }

    @discardableResult
    public func saveSkill(name: String, content: String) -> Bool {
        guard SkillPaths.isValidSkillName(name) else {
            lastErrorMessage = "技能名称不合法。仅支持字母、数字、点、下划线、中划线。"
            return false
        }
        let frontmatter = SkillFrontmatterParser.parse(content)
        guard let frontmatterName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              frontmatterName == name,
              frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            lastErrorMessage = "SKILL.md 格式错误：name 或 description 字段无效。"
            return false
        }

        let saved = SkillStore.saveSkill(name: name, content: content) != nil
        if !saved {
            lastErrorMessage = "保存技能失败。"
            return false
        }
        reloadFromDisk()
        enabledSkillNames.insert(name)
        persistEnabledSkillNames()
        lastErrorMessage = nil
        return true
    }

    @discardableResult
    public func saveSkillFilesAtomically(skillName: String, files: [String: String]) -> Bool {
        guard let skillMD = files["SKILL.md"] else {
            lastErrorMessage = "导入失败：缺少 SKILL.md。"
            return false
        }
        let frontmatter = SkillFrontmatterParser.parse(skillMD)
        guard let frontmatterName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              frontmatterName == skillName else {
            lastErrorMessage = "导入失败：SKILL.md 的 name 与技能目录名不一致。"
            return false
        }

        let saved = SkillStore.saveSkillFilesAtomically(skillName: skillName, files: files)
        if !saved {
            lastErrorMessage = "导入失败：写入技能目录失败。"
            return false
        }
        reloadFromDisk()
        enabledSkillNames.insert(skillName)
        persistEnabledSkillNames()
        lastErrorMessage = nil
        return true
    }

    @discardableResult
    public func deleteSkill(_ name: String) -> Bool {
        let deleted = SkillStore.deleteSkill(name: name)
        if deleted {
            enabledSkillNames.remove(name)
            persistEnabledSkillNames()
            reloadFromDisk()
        } else {
            lastErrorMessage = "删除技能失败。"
        }
        return deleted
    }

    public func listFiles(skillName: String) -> [SkillFileReference] {
        SkillStore.listSkillFiles(skillName: skillName)
    }

    public func readSkillFile(skillName: String, relativePath: String) -> String? {
        SkillStore.loadSkillFile(skillName: skillName, relativePath: relativePath)
    }

    @discardableResult
    public func saveSkillFile(skillName: String, relativePath: String, content: String) -> Bool {
        if relativePath == "SKILL.md" {
            let frontmatter = SkillFrontmatterParser.parse(content)
            let frontmatterName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if frontmatterName != skillName {
                lastErrorMessage = "不允许修改技能名称（name 必须保持为 \(skillName)）。"
                return false
            }
        }
        let success = SkillStore.saveSkillFile(skillName: skillName, relativePath: relativePath, content: content)
        if success {
            reloadFromDisk()
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "保存文件失败。"
        }
        return success
    }

    @discardableResult
    public func deleteSkillFile(skillName: String, relativePath: String) -> Bool {
        let success = SkillStore.deleteSkillFile(skillName: skillName, relativePath: relativePath)
        if success {
            reloadFromDisk()
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "删除文件失败。"
        }
        return success
    }

    public func resolveSkillFile(skillName: String, relativePath: String) -> URL? {
        SkillStore.resolveSkillFile(skillName: skillName, relativePath: relativePath)
    }

    public func readSkillBody(skillName: String) -> String? {
        SkillStore.readSkillBody(skillName: skillName)
    }

    public func readSkillContent(skillName: String) -> String? {
        SkillStore.readSkillContent(skillName: skillName)
    }

    public func importSkillFromGitHub(repoURL: String) async -> (success: Bool, message: String) {
        do {
            let result = try await SkillGitHubImporter.importSkill(from: repoURL)
            let saved = saveSkillFilesAtomically(skillName: result.skillName, files: result.files)
            if saved {
                return (true, result.skillName)
            }
            return (false, lastErrorMessage ?? "保存技能失败。")
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastErrorMessage = reason
            return (false, reason)
        }
    }

    // MARK: - Chat integration

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        let available = skills.filter { enabledSkillNames.contains($0.name) }
        guard !available.isEmpty else { return [] }
        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "name": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("要加载的技能名称。", comment: "Skill tool name parameter description sent to model"))
                ]),
                "path": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("技能目录内的相对路径。留空时默认读取 SKILL.md 正文。仅可使用 SKILL.md 中出现过的路径。", comment: "Skill tool path parameter description sent to model"))
                ])
            ]),
            "required": .array([.string("name")])
        ])

        let description = makeToolDescription(availableSkills: available)
        return [
            InternalToolDefinition(
                name: Self.chatToolName,
                description: description,
                parameters: parameters,
                isBlocking: true
            )
        ]
    }

    public nonisolated func displayLabel(for toolName: String) -> String? {
        guard toolName == Self.chatToolName else { return nil }
        return "Agent Skills"
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) throws -> String {
        guard toolName == Self.chatToolName else {
            throw SkillStoreError.invalidPath
        }
        guard chatToolsEnabled else {
            throw SkillStoreError.saveFailed("Agent Skills 总开关已关闭。")
        }

        struct UseSkillArgs: Decodable {
            let name: String
            let path: String?
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(UseSkillArgs.self, from: data) else {
            throw SkillStoreError.saveFailed("无法解析 use_skill 参数，请提供 name，path 可选。")
        }

        let name = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SkillStoreError.saveFailed("use_skill 的 name 不能为空。")
        }
        guard enabledSkillNames.contains(name) else {
            throw SkillStoreError.saveFailed("技能 \(name) 未启用。")
        }

        let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
            guard let body = readSkillBody(skillName: name) else {
                throw SkillStoreError.fileNotFound
            }
            return body
        }

        guard let skillContent = readSkillContent(skillName: name) else {
            throw SkillStoreError.fileNotFound
        }
        guard let normalizedPath = SkillLinkedPathPolicy.normalizeRelativePath(path) else {
            throw SkillStoreError.saveFailed("use_skill 的 path 无效。")
        }

        let linkedPaths = SkillLinkedPathPolicy.extractLinkedRelativePaths(from: skillContent)
        guard linkedPaths.contains(normalizedPath) else {
            throw SkillStoreError.saveFailed("use_skill 的 path 未在 SKILL.md 链接中声明：\(normalizedPath)")
        }

        guard let target = resolveSkillFile(skillName: name, relativePath: normalizedPath) else {
            throw SkillStoreError.invalidPath
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw SkillStoreError.fileNotFound
        }
        guard let content = try? String(contentsOf: target, encoding: .utf8) else {
            throw SkillStoreError.saveFailed("无法读取技能文件：\(normalizedPath)")
        }
        return content
    }

    // MARK: - Private

    private func makeToolDescription(availableSkills: [SkillMetadata]) -> String {
        var lines: [String] = []
        lines.append(NSLocalizedString("按需加载技能说明。仅当用户请求与某个技能匹配时调用 use_skill。", comment: "Skill tool description sent to model"))
        lines.append(NSLocalizedString("当前可用技能如下：", comment: "Available skills header sent to model"))
        lines.append("<available_skills>")
        for skill in availableSkills {
            lines.append("  <skill>")
            lines.append("    <name>\(skill.name)</name>")
            lines.append("    <description>\(skill.description)</description>")
            lines.append("  </skill>")
        }
        lines.append("</available_skills>")
        return ModelPromptLanguage.appendingToolArgumentInstruction(to: lines.joined(separator: "\n"))
    }

    private func pruneMissingEnabledSkills() {
        let existingNames = Set(skills.map(\.name))
        let filtered = enabledSkillNames.filter { existingNames.contains($0) }
        if filtered != enabledSkillNames {
            enabledSkillNames = filtered
            persistEnabledSkillNames()
        }
    }

    private func persistEnabledSkillNames() {
        defaults.set(enabledSkillNames.sorted(), forKey: DefaultsKey.enabledSkillNames)
    }
}

/// use_skill 的路径白名单策略：
/// - 仅允许读取 SKILL.md 里 Markdown 链接显式声明过的相对路径；
/// - 自动忽略锚点 / 查询参数 / 外链。
enum SkillLinkedPathPolicy {
    private static let inlineLinkRegex = try! NSRegularExpression(
        pattern: #"(?<!!)\[[^\]]+\]\(([^)\s]+|<[^>]+>)(?:\s+\"[^\"]*\")?\)"#,
        options: []
    )
    private static let referenceDefinitionRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)"#,
        options: []
    )
    private static let urlSchemeRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
        options: []
    )

    static func extractLinkedRelativePaths(from skillMarkdown: String) -> Set<String> {
        var paths: Set<String> = []

        let inlineTargets = captureTargets(
            from: skillMarkdown,
            regex: inlineLinkRegex,
            captureGroup: 1
        )
        for target in inlineTargets {
            if let normalized = normalizeRelativePath(target) {
                paths.insert(normalized)
            }
        }

        let referenceTargets = captureTargets(
            from: skillMarkdown,
            regex: referenceDefinitionRegex,
            captureGroup: 1
        )
        for target in referenceTargets {
            if let normalized = normalizeRelativePath(target) {
                paths.insert(normalized)
            }
        }

        return paths
    }

    static func normalizeRelativePath(_ rawPath: String) -> String? {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if normalized.hasPrefix("#") {
            return nil
        }
        if let queryIndex = normalized.firstIndex(of: "?") {
            normalized = String(normalized[..<queryIndex])
        }
        if let fragmentIndex = normalized.firstIndex(of: "#") {
            normalized = String(normalized[..<fragmentIndex])
        }

        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }

        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard !normalized.hasPrefix("/") else { return nil }
        guard !normalized.contains("\\") else { return nil }
        guard !normalized.split(separator: "/").contains("..") else { return nil }
        guard !hasURLScheme(normalized) else { return nil }
        return normalized
    }

    private static func captureTargets(
        from text: String,
        regex: NSRegularExpression,
        captureGroup: Int
    ) -> [String] {
        let range = NSRange(location: 0, length: text.utf16.count)
        let matches = regex.matches(in: text, options: [], range: range)
        let nsText = text as NSString
        return matches.compactMap { match in
            guard match.numberOfRanges > captureGroup else { return nil }
            let targetRange = match.range(at: captureGroup)
            guard targetRange.location != NSNotFound else { return nil }
            return nsText.substring(with: targetRange)
        }
    }

    private static func hasURLScheme(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: value.utf16.count)
        return urlSchemeRegex.firstMatch(in: value, options: [], range: range) != nil
    }
}
