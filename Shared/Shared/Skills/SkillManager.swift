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

    public enum SkillToolAction: String, Codable, Sendable {
        case readInstructions = "read_instructions"
        case listResources = "list_resources"
        case readResource = "read_resource"

        static func resolveToolArgument(_ rawValue: String) -> SkillToolAction? {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let action = SkillToolAction(rawValue: trimmed) {
                return action
            }

            let normalized = trimmed
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: #"[\s.-]+"#, with: "_", options: .regularExpression)
            switch normalized {
            case "read_instructions", "read_instruction", "readinstructions", "readinstruction", "instructions", "instruction", "skill", "skill_instructions":
                return .readInstructions
            case "list_resources", "list_resource", "listresources", "listresource", "resources", "resource_list":
                return .listResources
            case "read_resource", "readresource", "resource", "resource_content":
                return .readResource
            default:
                return nil
            }
        }
    }

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
        self.enabledSkillNames = Set(Self.stringArrayValue(forKey: DefaultsKey.enabledSkillNames, defaults: defaults))
        self.chatToolsEnabled = Self.boolValue(forKey: DefaultsKey.chatToolsEnabled, defaults: defaults, defaultValue: true)
        reloadFromDisk()
    }

    public nonisolated static func isSkillToolName(_ name: String) -> Bool {
        name == chatToolName
    }

    nonisolated static func resolveSkillNameForToolCall(
        _ requestedName: String,
        enabledSkillNames: Set<String>,
        skills: [SkillMetadata]
    ) -> String? {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let availableNames = skills.map(\.name).filter { enabledSkillNames.contains($0) }
        if availableNames.contains(trimmed) {
            return trimmed
        }

        let caseInsensitiveMatches = availableNames.filter {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if caseInsensitiveMatches.count == 1 {
            return caseInsensitiveMatches[0]
        }

        let lookupKey = normalizedSkillNameLookupKey(trimmed)
        guard !lookupKey.isEmpty else { return nil }
        let normalizedMatches = availableNames.filter {
            normalizedSkillNameLookupKey($0) == lookupKey
        }
        return normalizedMatches.count == 1 ? normalizedMatches[0] : nil
    }

    public func reloadFromDisk() {
        skills = SkillStore.listSkills()
        pruneMissingEnabledSkills()
    }

    public func setChatToolsEnabled(_ isEnabled: Bool) {
        guard chatToolsEnabled != isEnabled else { return }
        chatToolsEnabled = isEnabled
        Self.save(isEnabled, forKey: DefaultsKey.chatToolsEnabled, defaults: defaults)
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
        guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: nil) else {
            lastErrorMessage = "SKILL.md 缺少 name 字段。"
            return false
        }
        return saveSkill(name: manifest.name, content: content)
    }

    @discardableResult
    public func saveSkill(name: String, content: String) -> Bool {
        guard SkillPaths.isValidSkillName(name) else {
            lastErrorMessage = "技能名称不合法。仅支持字母、数字、点、下划线、中划线。"
            return false
        }
        guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: name),
              manifest.name == name else {
            lastErrorMessage = "SKILL.md 格式错误：name 字段无效。"
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
        let dataFiles = files.reduce(into: [String: Data]()) { result, element in
            result[element.key] = Data(element.value.utf8)
        }
        return saveSkillDataFilesAtomically(skillName: skillName, files: dataFiles)
    }

    @discardableResult
    public func saveSkillDataFilesAtomically(skillName: String, files: [String: Data]) -> Bool {
        guard let skillMD = files["SKILL.md"] else {
            lastErrorMessage = "导入失败：缺少 SKILL.md。"
            return false
        }
        guard let skillContent = String(data: skillMD, encoding: .utf8) else {
            lastErrorMessage = "导入失败：SKILL.md 不是 UTF-8 文本。"
            return false
        }
        guard let manifest = try? SkillManifestResolver.resolve(content: skillContent, fallbackName: skillName),
              manifest.name == skillName else {
            lastErrorMessage = "导入失败：SKILL.md 的 name 与技能目录名不一致。"
            return false
        }

        let saved = SkillStore.saveSkillDataFilesAtomically(skillName: skillName, files: files)
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
            guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: skillName),
                  manifest.name == skillName else {
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

    func restoreStateForTests(
        chatToolsEnabled: Bool,
        enabledSkillNames: Set<String>
    ) {
        self.chatToolsEnabled = chatToolsEnabled
        self.enabledSkillNames = enabledSkillNames
        persistEnabledSkillNames()
        Self.save(chatToolsEnabled, forKey: DefaultsKey.chatToolsEnabled, defaults: defaults)
        objectWillChange.send()
    }

    public func importSkillFromGitHub(repoURL: String) async -> (success: Bool, message: String) {
        do {
            let result = try await SkillGitHubImporter.importSkill(from: repoURL)
            let saved = saveSkillDataFilesAtomically(skillName: result.skillName, files: result.files)
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
        let actionDescription = [
            "\(SkillToolAction.readInstructions.rawValue): \(NSLocalizedString("读取 SKILL.md 正文说明。", comment: "Skill tool action description sent to model"))",
            "\(SkillToolAction.listResources.rawValue): \(NSLocalizedString("列出技能包内可发现资源。", comment: "Skill tool action description sent to model"))",
            "\(SkillToolAction.readResource.rawValue): \(NSLocalizedString("读取技能包内可读资源；文本文件原样读取，docx/pptx/xlsx 与支持平台上的 PDF 会抽取纯文本；scripts/ 仅允许读取，不能执行。", comment: "Skill tool action description sent to model"))"
        ].joined(separator: "\n")
        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "name": .dictionary([
                    "type": .string("string"),
                    "enum": .array(available.map { .string($0.name) }),
                    "description": .string(NSLocalizedString("要加载的技能名称。", comment: "Skill tool name parameter description sent to model"))
                ]),
                "action": .dictionary([
                    "type": .string("string"),
                    "enum": .array([
                        .string(SkillToolAction.readInstructions.rawValue),
                        .string(SkillToolAction.listResources.rawValue),
                        .string(SkillToolAction.readResource.rawValue)
                    ]),
                    "description": .string(actionDescription)
                ]),
                "path": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("技能目录内的相对路径，仅在 read_resource 时需要。可读取 references/、scripts/、agents/、assets/ 内的文本资源，并可从 docx/pptx/xlsx 与支持平台上的 PDF 抽取纯文本；不会执行 scripts/ 里的脚本。", comment: "Skill tool path parameter description sent to model"))
                ]),
                "start_line": .dictionary([
                    "type": .string("integer"),
                    "description": .string(NSLocalizedString("read_resource 分块读取的起始行号，从 1 开始；大文本资源建议使用。", comment: "Skill tool start line parameter description sent to model"))
                ]),
                "max_lines": .dictionary([
                    "type": .string("integer"),
                    "description": .string(NSLocalizedString("read_resource 分块读取的最多行数，默认 200，最大 1000。", comment: "Skill tool max lines parameter description sent to model"))
                ])
            ]),
            "required": .array([.string("name")])
        ])

        let description = Self.makeToolDescription(availableSkills: available)
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

    nonisolated static func makeToolDescriptionForTests(availableSkills: [SkillMetadata]) -> String {
        makeToolDescription(availableSkills: availableSkills)
    }

    public nonisolated func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard toolName == Self.chatToolName else {
            throw SkillStoreError.invalidPath
        }
        let snapshot = await MainActor.run {
            (
                chatToolsEnabled: self.chatToolsEnabled,
                enabledSkillNames: self.enabledSkillNames,
                skills: self.skills
            )
        }
        guard snapshot.chatToolsEnabled else {
            throw SkillStoreError.saveFailed("Agent Skills 总开关已关闭。")
        }

        struct UseSkillArgs: Decodable {
            let name: String
            let action: String?
            let path: String?
            let start_line: Int?
            let max_lines: Int?
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(UseSkillArgs.self, from: data) else {
            throw SkillStoreError.saveFailed("无法解析 use_skill 参数，请提供 name，path 可选。")
        }

        let requestedName = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            throw SkillStoreError.saveFailed("use_skill 的 name 不能为空。")
        }
        guard let name = Self.resolveSkillNameForToolCall(
            requestedName,
            enabledSkillNames: snapshot.enabledSkillNames,
            skills: snapshot.skills
        ) else {
            throw SkillStoreError.saveFailed("技能 \(requestedName) 未启用或不存在。")
        }

        let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let action: SkillToolAction
        if let rawAction = args.action?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAction.isEmpty {
            guard let resolvedAction = SkillToolAction.resolveToolArgument(rawAction) else {
                throw SkillStoreError.saveFailed("use_skill 的 action 无效：\(rawAction)。")
            }
            action = resolvedAction
        } else {
            action = path.isEmpty ? .readInstructions : .readResource
        }
        return try await Task.detached(priority: .utility) {
            switch action {
            case .readInstructions:
                guard path.isEmpty || path == SkillStore.defaultSkillFileName else {
                    throw SkillStoreError.saveFailed("read_instructions 不需要 path；读取其他文件请使用 read_resource。")
                }
                guard let body = SkillStore.readSkillBody(skillName: name) else {
                    throw SkillStoreError.fileNotFound
                }
                return body
            case .listResources:
                let files = SkillStore.listSkillFiles(skillName: name)
                return Self.formatResourceList(skillName: name, files: files)
            case .readResource:
                guard !path.isEmpty else {
                    throw SkillStoreError.saveFailed("read_resource 必须提供 path。")
                }
                if args.start_line != nil || args.max_lines != nil {
                    let chunk = try await SkillStore.loadSkillReadableResourceChunk(
                        skillName: name,
                        relativePath: path,
                        startLine: args.start_line ?? 1,
                        maxLines: args.max_lines ?? 200
                    )
                    return Self.formatResourceChunk(skillName: name, chunk: chunk)
                }
                let content = try await SkillStore.loadSkillReadableResource(skillName: name, relativePath: path)
                let normalizedPath = SkillResourcePolicy.normalizeRelativePath(path) ?? path
                return Self.formatResourceContent(skillName: name, relativePath: normalizedPath, content: content)
            }
        }.value
    }

    private nonisolated static func formatResourceList(skillName: String, files: [SkillFileReference]) -> String {
        guard !files.isEmpty else {
            return String(format: NSLocalizedString("技能 %@ 没有可列出的资源。", comment: "Skill resource list empty result"), skillName)
        }

        var lines = [
            String(format: NSLocalizedString("技能 %@ 的资源列表：", comment: "Skill resource list header"), skillName)
        ]
        for file in files {
            let access = file.isReadableText
                ? NSLocalizedString("可读取", comment: "Skill resource readable marker")
                : (file.readOnlyReason ?? NSLocalizedString("仅列出", comment: "Skill resource list-only marker"))
            lines.append("- \(file.relativePath) (\(StorageUtility.formatSize(file.size)), \(access))")
        }
        lines.append(NSLocalizedString("使用 action=read_resource 和对应 path 读取可读资源；文本文件原样读取，docx/pptx/xlsx 与支持平台上的 PDF 会抽取纯文本；大文件可额外提供 start_line 与 max_lines 分块读取；scripts/ 资源只会返回源码，不会执行。", comment: "Skill resource list footer sent to model"))
        return lines.joined(separator: "\n")
    }

    private nonisolated static func formatResourceChunk(skillName: String, chunk: SkillTextResourceChunk) -> String {
        [
            String(
                format: NSLocalizedString("技能 %@ 资源：%@（第 %d-%d 行，共 %d 行，%@）", comment: "Skill resource chunk content header"),
                skillName,
                chunk.relativePath,
                chunk.startLine,
                chunk.endLine,
                chunk.totalLines,
                chunk.hasMore ? NSLocalizedString("还有更多", comment: "Skill resource chunk has more marker") : NSLocalizedString("已到末尾", comment: "Skill resource chunk end marker")
            ),
            "",
            chunk.content
        ].joined(separator: "\n")
    }

    private nonisolated static func formatResourceContent(skillName: String, relativePath: String, content: String) -> String {
        [
            String(format: NSLocalizedString("技能 %@ 资源：%@", comment: "Skill resource content header"), skillName, relativePath),
            "",
            content
        ].joined(separator: "\n")
    }

    // MARK: - Private

    private nonisolated static func makeToolDescription(availableSkills: [SkillMetadata]) -> String {
        var lines: [String] = []
        lines.append(NSLocalizedString("按需加载技能说明。仅当用户请求与某个技能匹配时调用 use_skill。", comment: "Skill tool description sent to model"))
        lines.append(NSLocalizedString("先用 read_instructions 加载技能正文；需要额外资料时用 list_resources 查看资源，再用 read_resource 读取 references/scripts/agents/assets 中的可读资源。文本文件原样读取，docx/pptx/xlsx 与支持平台上的 PDF 会抽取纯文本；scripts 只能读取源码，不能执行。", comment: "Skill progressive disclosure tool instruction sent to model"))
        lines.append(NSLocalizedString("SKILL.md 里的 allowed-tools 仅作为技能作者说明；当前应用仍只提供 use_skill 读取能力，不会执行脚本或本地命令。", comment: "Skill allowed tools limitation sent to model"))
        lines.append(NSLocalizedString("当前可用技能如下：", comment: "Available skills header sent to model"))
        lines.append("<available_skills>")
        for skill in availableSkills {
            lines.append("  <skill>")
            lines.append("    <name>\(Self.escapeXMLText(skill.name))</name>")
            lines.append("    <description>\(Self.escapeXMLText(skill.description))</description>")
            if let compatibility = skill.compatibility?.trimmingCharacters(in: .whitespacesAndNewlines), !compatibility.isEmpty {
                lines.append("    <compatibility>\(Self.escapeXMLText(compatibility))</compatibility>")
            }
            if !skill.allowedTools.isEmpty {
                lines.append("    <allowed_tools>\(Self.escapeXMLText(skill.allowedTools.joined(separator: ", ")))</allowed_tools>")
            }
            lines.append("  </skill>")
        }
        lines.append("</available_skills>")
        return ModelPromptLanguage.appendingToolArgumentInstruction(to: lines.joined(separator: "\n"))
    }

    private nonisolated static func escapeXMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private nonisolated static func normalizedSkillNameLookupKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[\s._-]+"#, with: "", options: .regularExpression)
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
        Self.save(enabledSkillNames.sorted(), forKey: DefaultsKey.enabledSkillNames, defaults: defaults)
    }

    private static func usesDatabase(defaults: UserDefaults) -> Bool {
        defaults === UserDefaults.standard
    }

    private static func boolValue(forKey key: String, defaults: UserDefaults, defaultValue: Bool) -> Bool {
        if key == DefaultsKey.chatToolsEnabled, usesDatabase(defaults: defaults) {
            return AppConfigStore.boolValue(for: .skillsChatToolsEnabled, defaultValue: defaultValue)
        }
        guard usesDatabase(defaults: defaults) else {
            return defaults.object(forKey: key) as? Bool ?? defaultValue
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigInteger(key: key) {
            return stored != 0
        }
        return defaultValue
    }

    private static func stringArrayValue(forKey key: String, defaults: UserDefaults) -> [String] {
        if key == DefaultsKey.enabledSkillNames, usesDatabase(defaults: defaults) {
            return AppConfigStore.stringArrayValue(for: .skillsEnabledNames, defaultValue: []) ?? []
        }
        guard usesDatabase(defaults: defaults) else {
            return defaults.stringArray(forKey: key) ?? []
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigText(key: key),
           let decoded = decodeStringArray(stored) {
            return decoded
        }
        return []
    }

    private static func save(_ value: Bool, forKey key: String, defaults: UserDefaults) {
        if key == DefaultsKey.chatToolsEnabled, usesDatabase(defaults: defaults) {
            AppConfigStore.persistSynchronously(.bool(value), for: .skillsChatToolsEnabled)
            return
        }
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        Persistence.writeAppConfig(key: key, integer: value ? 1 : 0, typeHint: "bool")
    }

    private static func save(_ value: [String], forKey key: String, defaults: UserDefaults) {
        if key == DefaultsKey.enabledSkillNames, usesDatabase(defaults: defaults) {
            AppConfigStore.persistStringArray(value, for: .skillsEnabledNames)
            return
        }
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        guard let encoded = encodeStringArray(value) else { return }
        Persistence.writeAppConfig(key: key, text: encoded, typeHint: "text")
    }

    private static func encodeStringArray(_ value: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeStringArray(_ value: String) -> [String]? {
        guard let data = value.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String]
    }
}

/// use_skill 的 Markdown 链接发现策略。
/// 保留该策略用于测试与旧数据兼容；实际资源读取统一走 SkillResourcePolicy。
enum SkillLinkedPathPolicy {
    private static let inlineLinkRegex = try! NSRegularExpression(
        pattern: #"\[[^\]]+\]\(([^)\s]+|<[^>]+>)(?:\s+\"[^\"]*\")?\)"#,
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
        return SkillResourcePolicy.normalizeRelativePath(normalized)
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
