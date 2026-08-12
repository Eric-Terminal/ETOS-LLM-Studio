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
        case executeScript = "execute_script"

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
            case "execute_script", "executescript", "execute":
                return .executeScript
            default:
                return nil
            }
        }
    }

    private struct UseSkillArgs: Decodable {
        let name: String
        let action: String?
        let path: String?
        let startLine: Int?
        let maxLines: Int?
        let arguments: [String]?
        let timeoutSeconds: Double?
        let outputLimitBytes: UInt64?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
            guard let name = try Self.decodeString(
                from: container,
                keys: ["name", "skill_name", "skillName", "skill"]
            ) else {
                throw DecodingError.keyNotFound(
                    FlexibleCodingKey("name"),
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing skill name")
                )
            }
            self.name = name
            self.action = try Self.decodeString(from: container, keys: ["action", "operation"])
            self.path = try Self.decodeString(
                from: container,
                keys: ["path", "resource_path", "resourcePath", "file_path", "filePath", "file"]
            )
            self.startLine = try Self.decodeInt(
                from: container,
                keys: ["start_line", "startLine", "line_start", "lineStart"]
            )
            self.maxLines = try Self.decodeInt(
                from: container,
                keys: ["max_lines", "maxLines", "line_count", "lineCount", "limit"]
            )
            self.arguments = try Self.decodeStringArray(
                from: container,
                keys: ["arguments", "args", "argv"]
            )
            self.timeoutSeconds = try Self.decodeDouble(
                from: container,
                keys: ["timeout_seconds", "timeoutSeconds"]
            )
            self.outputLimitBytes = try Self.decodeUInt64(
                from: container,
                keys: ["output_limit_bytes", "outputLimitBytes"]
            )
        }

        private static func decodeString(
            from container: KeyedDecodingContainer<FlexibleCodingKey>,
            keys: [String]
        ) throws -> String? {
            for key in keys {
                let codingKey = FlexibleCodingKey(key)
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                    return value
                }
            }
            return nil
        }

        private static func decodeInt(
            from container: KeyedDecodingContainer<FlexibleCodingKey>,
            keys: [String]
        ) throws -> Int? {
            for key in keys {
                let codingKey = FlexibleCodingKey(key)
                if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                    return value
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
                   let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return intValue
                }
            }
            return nil
        }

        private static func decodeStringArray(
            from container: KeyedDecodingContainer<FlexibleCodingKey>,
            keys: [String]
        ) throws -> [String]? {
            for key in keys {
                if let value = try? container.decodeIfPresent([String].self, forKey: FlexibleCodingKey(key)) {
                    return value
                }
            }
            return nil
        }

        private static func decodeDouble(
            from container: KeyedDecodingContainer<FlexibleCodingKey>,
            keys: [String]
        ) throws -> Double? {
            for key in keys {
                let codingKey = FlexibleCodingKey(key)
                if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                    return value
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
                   let number = Double(value) {
                    return number
                }
            }
            return nil
        }

        private static func decodeUInt64(
            from container: KeyedDecodingContainer<FlexibleCodingKey>,
            keys: [String]
        ) throws -> UInt64? {
            for key in keys {
                let codingKey = FlexibleCodingKey(key)
                if let value = try? container.decodeIfPresent(UInt64.self, forKey: codingKey) {
                    return value
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
                   let number = UInt64(value) {
                    return number
                }
            }
            return nil
        }
    }

    private struct FlexibleCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
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
        let newlyInstalledBuiltInSkillNames = SkillStore.installBuiltInSkillsIfNeeded()
        self.defaults = defaults
        self.enabledSkillNames = Set(Self.stringArrayValue(forKey: DefaultsKey.enabledSkillNames, defaults: defaults))
        self.chatToolsEnabled = Self.boolValue(forKey: DefaultsKey.chatToolsEnabled, defaults: defaults, defaultValue: true)
        if !newlyInstalledBuiltInSkillNames.isEmpty {
            enabledSkillNames.formUnion(newlyInstalledBuiltInSkillNames)
            persistEnabledSkillNames()
        }
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

    public func executionPolicyStatus(skillName: String) async -> SkillExecutionPolicyStatus {
        let metadata = skills.first { $0.name == skillName }
        return await Task.detached(priority: .utility) {
            let record = Persistence.skillExecutionPolicy(skillName: skillName)
            let digest = metadata.flatMap { try? SkillRunSnapshotBuilder.build(skill: $0).versionDigest }
            return SkillExecutionPolicyStatus(record: record, currentVersionDigest: digest)
        }.value
    }

    @discardableResult
    public func setExecutionPolicy(
        _ policy: SkillExecutionPolicy,
        skillName: String
    ) async -> Bool {
        guard let metadata = skills.first(where: { $0.name == skillName }) else { return false }
        let record = await Task.detached(priority: .utility) {
            let digest: String?
            if policy == .allowCurrentVersion {
                digest = try? SkillRunSnapshotBuilder.build(skill: metadata).versionDigest
            } else {
                digest = nil
            }
            return SkillExecutionPolicyRecord(
                skillName: skillName,
                policy: policy,
                approvedVersionDigest: digest
            )
        }.value
        guard policy != .allowCurrentVersion || record.approvedVersionDigest != nil else {
            lastErrorMessage = NSLocalizedString("无法读取当前 Skill 版本，未保存执行授权。", comment: "Cannot approve unreadable Skill version")
            return false
        }
        let saved = await Task.detached(priority: .utility) {
            Persistence.saveSkillExecutionPolicy(record)
        }.value
        if !saved {
            lastErrorMessage = NSLocalizedString("保存 Skill 执行策略失败。", comment: "Save Skill execution policy failure")
        }
        return saved
    }

    @discardableResult
    public func saveSkillFromContent(_ content: String, fallbackName: String? = nil) -> Bool {
        if let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: nil) {
            return saveSkill(name: manifest.name, content: content)
        }

        let fallback = fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fallback.isEmpty else {
            lastErrorMessage = NSLocalizedString("SKILL.md 缺少 name 字段。", comment: "Skill manifest missing name")
            return false
        }
        guard SkillPaths.isValidSkillName(fallback) else {
            lastErrorMessage = NSLocalizedString("技能名称不合法。仅支持字母、数字、点、下划线、中划线。", comment: "Invalid skill name characters")
            return false
        }
        guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: fallback) else {
            lastErrorMessage = NSLocalizedString("SKILL.md 格式错误：name 字段无效。", comment: "Invalid skill manifest name")
            return false
        }
        return saveSkill(name: manifest.name, content: content)
    }

    @discardableResult
    public func saveSkill(name: String, content: String) -> Bool {
        guard SkillPaths.isValidSkillName(name) else {
            lastErrorMessage = NSLocalizedString("技能名称不合法。仅支持字母、数字、点、下划线、中划线。", comment: "Invalid skill name characters")
            return false
        }
        guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: name),
              manifest.name == name else {
            lastErrorMessage = NSLocalizedString("SKILL.md 格式错误：name 字段无效。", comment: "Invalid skill manifest name")
            return false
        }

        let saved = SkillStore.saveSkill(name: name, content: content) != nil
        if !saved {
            lastErrorMessage = NSLocalizedString("保存技能失败。", comment: "Save skill failure")
            return false
        }
        reloadFromDisk()
        enabledSkillNames.insert(name)
        persistEnabledSkillNames()
        lastErrorMessage = nil
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
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
            lastErrorMessage = NSLocalizedString("导入失败：缺少 SKILL.md。", comment: "Skill import missing manifest")
            return false
        }
        guard let skillContent = String(data: skillMD, encoding: .utf8) else {
            lastErrorMessage = NSLocalizedString("导入失败：SKILL.md 不是 UTF-8 文本。", comment: "Skill import manifest is not UTF-8")
            return false
        }
        guard let manifest = try? SkillManifestResolver.resolve(content: skillContent, fallbackName: skillName),
              manifest.name == skillName else {
            lastErrorMessage = NSLocalizedString("导入失败：SKILL.md 的 name 与技能目录名不一致。", comment: "Skill import name mismatch")
            return false
        }

        let saved = SkillStore.saveSkillDataFilesAtomically(skillName: skillName, files: files)
        if !saved {
            lastErrorMessage = NSLocalizedString("导入失败：写入技能目录失败。", comment: "Skill import directory write failure")
            return false
        }
        reloadFromDisk()
        enabledSkillNames.insert(skillName)
        persistEnabledSkillNames()
        lastErrorMessage = nil
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        return true
    }

    @discardableResult
    public func deleteSkill(_ name: String) -> Bool {
        let deleted = SkillStore.deleteSkill(name: name)
        if deleted {
            enabledSkillNames.remove(name)
            persistEnabledSkillNames()
            reloadFromDisk()
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } else {
            lastErrorMessage = NSLocalizedString("删除技能失败。", comment: "Delete skill failure")
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
                lastErrorMessage = String(
                    format: NSLocalizedString("不允许修改技能名称（name 必须保持为 %@）。", comment: "Skill name modification forbidden"),
                    skillName
                )
                return false
            }
        }
        let success = SkillStore.saveSkillFile(skillName: skillName, relativePath: relativePath, content: content)
        if success {
            reloadFromDisk()
            lastErrorMessage = nil
        } else {
            lastErrorMessage = NSLocalizedString("保存文件失败。", comment: "Save skill file failure")
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
            lastErrorMessage = NSLocalizedString("删除文件失败。", comment: "Delete skill file failure")
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

    @discardableResult
    public func updateSkillContent(oldName: String, content: String, fallbackName: String? = nil) -> Bool {
        let sourceName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceName.isEmpty else {
            lastErrorMessage = NSLocalizedString("技能名称不能为空。", comment: "Skill name empty error")
            return false
        }
        guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: fallbackName ?? sourceName) else {
            lastErrorMessage = NSLocalizedString("SKILL.md 格式错误：name 字段无效。", comment: "Skill manifest invalid error")
            return false
        }
        let targetName = manifest.name
        guard SkillPaths.isValidSkillName(targetName) else {
            lastErrorMessage = NSLocalizedString("技能名称不合法。仅支持字母、数字、点、下划线、中划线。", comment: "Invalid skill name detail")
            return false
        }
        guard let files = SkillStore.readAllSkillFileData(skillName: sourceName) else {
            lastErrorMessage = NSLocalizedString("无法读取原技能文件。", comment: "Read original skill files failed")
            return false
        }
        if sourceName != targetName, SkillStore.skillExists(targetName) {
            lastErrorMessage = NSLocalizedString("已有同名技能。", comment: "Duplicate skill name error")
            return false
        }

        var updatedFiles = files
        updatedFiles[SkillStore.defaultSkillFileName] = Data(content.utf8)
        let wasEnabled = enabledSkillNames.contains(sourceName)
        let saved = SkillStore.replaceSkillDataFilesAtomically(
            oldSkillName: sourceName,
            newSkillName: targetName,
            files: updatedFiles
        )
        guard saved else {
            lastErrorMessage = NSLocalizedString("更新技能失败。", comment: "Update skill failed")
            return false
        }

        if sourceName != targetName {
            enabledSkillNames.remove(sourceName)
        }
        if wasEnabled {
            enabledSkillNames.insert(targetName)
        }
        persistEnabledSkillNames()
        reloadFromDisk()
        lastErrorMessage = nil
        return true
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
            return (
                false,
                lastErrorMessage ?? NSLocalizedString("保存技能失败。", comment: "Save skill failure")
            )
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastErrorMessage = reason
            return (false, reason)
        }
    }

    public func importSkillFromURL(
        urlString: String,
        progress: SyncPackageUploadService.DownloadProgressHandler? = nil
    ) async -> (success: Bool, message: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let message = NSLocalizedString("链接不能为空。", comment: "")
            lastErrorMessage = message
            return (false, message)
        }
        guard let url = URL(string: trimmed) else {
            let message = NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "")
            lastErrorMessage = message
            return (false, message)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            let message = NSLocalizedString("仅支持 http/https 链接。", comment: "")
            lastErrorMessage = message
            return (false, message)
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 45
            progress?(SyncPackageDownloadProgress(bytesReceived: 0, totalBytes: 0))
            let (downloadedURL, response) = try await SyncPackageUploadService.downloadTemporaryFile(
                request: request,
                progress: progress
            )
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let message = String(format: NSLocalizedString("下载失败：HTTP %d", comment: ""), httpResponse.statusCode)
                lastErrorMessage = message
                return (false, message)
            }

            let suggestedFilename = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldUseSourcePath = suggestedFilename?.isEmpty != false
                || suggestedFilename?.caseInsensitiveCompare(SkillStore.defaultSkillFileName) == .orderedSame
            let fileName = shouldUseSourcePath ? url.path : suggestedFilename!
            let data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: downloadedURL)
            }.value
            let completedBytes = Int64(data.count)
            progress?(SyncPackageDownloadProgress(bytesReceived: completedBytes, totalBytes: completedBytes))
            let result = try await Task.detached(priority: .utility) {
                try SkillBundleImporter.importSkill(fromDownloadedData: data, suggestedFileName: fileName)
            }.value
            let saved = saveSkillDataFilesAtomically(skillName: result.skillName, files: result.files)
            if saved {
                return (true, result.skillName)
            }
            return (false, lastErrorMessage ?? NSLocalizedString("导入失败：技能包内容无效。", comment: ""))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastErrorMessage = reason
            return (false, reason)
        }
    }

    // MARK: - Chat integration

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        let available = skills
            .filter { enabledSkillNames.contains($0.name) }
            .sorted { lhs, rhs in
                let lhsName = lhs.name.lowercased()
                let rhsName = rhs.name.lowercased()
                if lhsName != rhsName {
                    return lhsName < rhsName
                }
                return lhs.name < rhs.name
            }
        guard !available.isEmpty else { return [] }
        let actionDescription = [
            "\(SkillToolAction.readInstructions.rawValue): \(NSLocalizedString("读取 SKILL.md 正文说明。", comment: "Skill tool action description sent to model"))",
            "\(SkillToolAction.listResources.rawValue): \(NSLocalizedString("列出技能包内可发现资源。", comment: "Skill tool action description sent to model"))",
            "\(SkillToolAction.readResource.rawValue): \(NSLocalizedString("读取技能包内可读资源；文本文件原样读取，docx/pptx/xlsx 与支持平台上的 PDF 会抽取纯文本。", comment: "Skill tool action description sent to model"))",
            "\(SkillToolAction.executeScript.rawValue): \(NSLocalizedString("在当前 Agent Run 的本地 Linux 中执行 scripts/ 内脚本；Skill 只读，工作区可写，且可能需要用户授权。", comment: "Skill execute script action description sent to model"))"
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
                        .string(SkillToolAction.readResource.rawValue),
                        .string(SkillToolAction.executeScript.rawValue)
                    ]),
                    "description": .string(actionDescription)
                ]),
                "path": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("技能目录内的相对路径。read_resource 可读取资源；execute_script 只接受 scripts/ 内文件。", comment: "Skill tool path parameter description sent to model"))
                ]),
                "start_line": .dictionary([
                    "type": .string("integer"),
                    "description": .string(NSLocalizedString("read_resource 分块读取的起始行号，从 1 开始；大文本资源建议使用。", comment: "Skill tool start line parameter description sent to model"))
                ]),
                "max_lines": .dictionary([
                    "type": .string("integer"),
                    "description": .string(NSLocalizedString("read_resource 分块读取的最多行数，默认 200，最大 1000。", comment: "Skill tool max lines parameter description sent to model"))
                ]),
                "arguments": .dictionary([
                    "type": .string("array"),
                    "items": .dictionary(["type": .string("string")]),
                    "description": .string(NSLocalizedString("execute_script 的 argv 参数数组；不会经过 shell 拼接。", comment: "Skill script argv description sent to model"))
                ]),
                "timeout_seconds": .dictionary([
                    "type": .string("number"),
                    "minimum": .int(1),
                    "maximum": .int(3600),
                    "description": .string(NSLocalizedString("execute_script 的超时秒数。", comment: "Skill script timeout description sent to model"))
                ]),
                "output_limit_bytes": .dictionary([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(16777216),
                    "description": .string(NSLocalizedString("execute_script 的输出终止阈值。", comment: "Skill script output limit description sent to model"))
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

    public nonisolated func executeToolFromChat(
        toolName: String,
        argumentsJSON: String,
        sourceSessionID: UUID? = nil,
        sourceAgentRunID: UUID? = nil,
        triggeringMessageID: UUID? = nil,
        sourceToolCallID: String? = nil
    ) async throws -> String {
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
            throw SkillStoreError.saveFailed(
                NSLocalizedString("Agent Skills 总开关已关闭。", comment: "Agent Skills tool group disabled")
            )
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(UseSkillArgs.self, from: data) else {
            throw SkillStoreError.saveFailed(
                NSLocalizedString("无法解析 use_skill 参数，请提供 name，path 可选。", comment: "Invalid use_skill arguments")
            )
        }

        let requestedName = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            throw SkillStoreError.saveFailed(
                NSLocalizedString("use_skill 的 name 不能为空。", comment: "use_skill name is empty")
            )
        }
        guard let name = Self.resolveSkillNameForToolCall(
            requestedName,
            enabledSkillNames: snapshot.enabledSkillNames,
            skills: snapshot.skills
        ) else {
            throw SkillStoreError.saveFailed(
                String(format: NSLocalizedString("技能 %@ 未启用或不存在。", comment: "Requested skill unavailable"), requestedName)
            )
        }

        let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let action: SkillToolAction
        if let rawAction = args.action?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAction.isEmpty {
            guard let resolvedAction = SkillToolAction.resolveToolArgument(rawAction) else {
                throw SkillStoreError.saveFailed(
                    String(format: NSLocalizedString("use_skill 的 action 无效：%@。", comment: "Invalid use_skill action"), rawAction)
                )
            }
            action = resolvedAction
        } else {
            action = path.isEmpty ? .readInstructions : .readResource
        }
        if action != .executeScript,
           let sourceAgentRunID,
           let runRecord = Persistence.loadLocalAgentRun(id: sourceAgentRunID) {
            guard let frozenSkill = runRecord.context.skillSnapshots?.first(where: { $0.skillName == name }) else {
                throw SkillExecutionError.skillNotFrozen
            }
            guard let metadata = snapshot.skills.first(where: { $0.name == name }) else {
                throw SkillExecutionError.skillChanged
            }
            let currentDigest = try await Task.detached(priority: .utility) {
                try SkillRunSnapshotBuilder.build(skill: metadata).versionDigest
            }.value
            guard currentDigest == frozenSkill.versionDigest else {
                throw SkillExecutionError.skillChanged
            }
        }
        if action == .executeScript {
            guard !path.isEmpty else {
                throw SkillStoreError.saveFailed(
                    NSLocalizedString("execute_script 必须提供 scripts/ 内的 path。", comment: "Skill execute script path required")
                )
            }
            guard let sourceSessionID, let sourceAgentRunID, let sourceToolCallID else {
                throw SkillExecutionError.agentContextRequired
            }
            let result = try await SkillScriptToolExecutor.shared.execute(
                skillName: name,
                relativePath: path,
                arguments: args.arguments ?? [],
                timeoutSeconds: args.timeoutSeconds,
                outputLimitBytes: args.outputLimitBytes,
                sessionID: sourceSessionID,
                runID: sourceAgentRunID,
                triggeringMessageID: triggeringMessageID,
                toolCallID: sourceToolCallID
            )
            if let runRecord = Persistence.loadLocalAgentRun(id: sourceAgentRunID),
               let frozenSkill = runRecord.context.skillSnapshots?.first(where: { $0.skillName == name }) {
                await SkillAllowedToolRuntime.shared.activate(skill: frozenSkill, runID: sourceAgentRunID)
            }
            return result
        }
        let result = try await Task.detached(priority: .utility) {
            switch action {
            case .readInstructions:
                guard path.isEmpty || path == SkillStore.defaultSkillFileName else {
                    throw SkillStoreError.saveFailed(
                        NSLocalizedString(
                            "read_instructions 不需要 path；读取其他文件请使用 read_resource。",
                            comment: "read_instructions received a resource path"
                        )
                    )
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
                    throw SkillStoreError.saveFailed(
                        NSLocalizedString("read_resource 必须提供 path。", comment: "read_resource path is required")
                    )
                }
                if args.startLine != nil || args.maxLines != nil {
                    let chunk = try await SkillStore.loadSkillReadableResourceChunk(
                        skillName: name,
                        relativePath: path,
                        startLine: args.startLine ?? 1,
                        maxLines: args.maxLines ?? 200
                    )
                    return Self.formatResourceChunk(skillName: name, chunk: chunk)
                }
                let content = try await SkillStore.loadSkillReadableResource(skillName: name, relativePath: path)
                let normalizedPath = SkillResourcePolicy.normalizeRelativePath(path) ?? path
                return Self.formatResourceContent(skillName: name, relativePath: normalizedPath, content: content)
            case .executeScript:
                preconditionFailure("execute_script 应在进入资源读取任务前处理。")
            }
        }.value
        if let sourceAgentRunID {
            if let runRecord = Persistence.loadLocalAgentRun(id: sourceAgentRunID),
               let frozenSkill = runRecord.context.skillSnapshots?.first(where: { $0.skillName == name }) {
                await SkillAllowedToolRuntime.shared.activate(skill: frozenSkill, runID: sourceAgentRunID)
            } else if let metadata = snapshot.skills.first(where: { $0.name == name }) {
                await SkillAllowedToolRuntime.shared.activate(
                    skillName: metadata.name,
                    allowedTools: metadata.allowedTools,
                    runID: sourceAgentRunID
                )
            }
        }
        return result
    }

    private nonisolated static func formatResourceList(skillName: String, files: [SkillFileReference]) -> String {
        guard !files.isEmpty else {
            return String(format: NSLocalizedString("技能 %@ 没有可列出的资源。", comment: "Skill resource list empty result"), skillName)
        }

        var lines = [
            String(format: NSLocalizedString("技能 %@ 的资源列表：", comment: "Skill resource list header"), skillName)
        ]
        for file in files {
            let access: String
            if file.isReadableText {
                access = file.readOnlyReason ?? NSLocalizedString("可读取", comment: "Skill resource readable marker")
            } else {
                access = file.readOnlyReason ?? NSLocalizedString("仅列出", comment: "Skill resource list-only marker")
            }
            lines.append("- \(file.relativePath) (\(StorageUtility.formatSize(file.size)), \(access))")
        }
        lines.append(NSLocalizedString("使用 action=read_resource 和对应 path 读取可读资源；文本文件原样读取，docx/pptx/xlsx 与支持平台上的 PDF 会抽取纯文本；大文件可额外提供 start_line 与 max_lines 分块读取。scripts/ 源码可读取；只有 execute_script 会在授权后执行。", comment: "Skill resource list footer sent to model"))
        lines.append(NSLocalizedString("支持平台上的图片资源会尝试 OCR；常见非 UTF-8 文本编码会尝试解码。", comment: "Skill resource readable formats note sent to model"))
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
        lines.append(NSLocalizedString("先用 read_instructions 加载技能正文；需要额外资料时用 list_resources 查看资源，再用 read_resource 读取 references/scripts/agents/assets 中的可读资源。只有在 Agent 模式、本地 Linux 与该 Skill 均已启用时，才可用 execute_script 执行 scripts/ 内文件。", comment: "Skill progressive disclosure tool instruction sent to model"))
        lines.append(NSLocalizedString("支持平台上的图片资源会尝试 OCR；常见非 UTF-8 文本编码会尝试解码。", comment: "Skill resource readable formats note sent to model"))
        lines.append(NSLocalizedString("SKILL.md 的 allowed-tools 只是不超过当前会话已启用工具的权限上限，不能新增工具、绕过工具开关或替代用户审批。", comment: "Skill allowed tools limitation sent to model"))
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
        return lines.joined(separator: "\n")
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
