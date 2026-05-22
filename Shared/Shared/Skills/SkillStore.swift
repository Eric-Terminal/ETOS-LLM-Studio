// ============================================================================
// SkillStore.swift
// ============================================================================
// Agent Skills 持久化存储
// - 目录级技能文件读写（每个技能一个目录）
// - 原子替换保存
// - 文件索引与正文读取
// - 同步导入/导出辅助
// ============================================================================

import Foundation
import os.log

private let skillStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SkillStore")

public enum SkillStore {
    public static let directoryName = "Skills"
    public static let defaultSkillFileName = "SKILL.md"

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static var skillsDirectory: URL {
        documentsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    public static func setupDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        let dir = skillsDirectory
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                skillStoreLogger.info("Skills 目录已创建: \(dir.path, privacy: .public)")
            } catch {
                skillStoreLogger.error("创建 Skills 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return dir
    }

    public static func listSkills() -> [SkillMetadata] {
        let root = setupDirectoryIfNeeded()
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let skills = dirs.compactMap { dir -> SkillMetadata? in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let skillFile = dir.appendingPathComponent(defaultSkillFileName, isDirectory: false)
            guard fm.fileExists(atPath: skillFile.path) else { return nil }
            return parseMetadata(from: skillFile)
        }
        return skills.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func readSkillBody(skillName: String) -> String? {
        guard let fileURL = resolveSkillFile(skillName: skillName, relativePath: defaultSkillFileName),
              FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        return SkillFrontmatterParser.extractBody(content)
    }

    public static func readSkillContent(skillName: String) -> String? {
        guard let fileURL = resolveSkillFile(skillName: skillName, relativePath: defaultSkillFileName),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    public static func listSkillFiles(skillName: String) -> [SkillFileReference] {
        guard let skillDir = resolveSkillDir(skillName: skillName),
              FileManager.default.fileExists(atPath: skillDir.path) else {
            return []
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: skillDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [SkillFileReference] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isDirectory != true else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: skillDir.path + "/", with: "")
            let size = Int64(values.fileSize ?? 0)
            let readability = textReadability(fileURL: fileURL, relativePath: relativePath, size: size)
            files.append(
                SkillFileReference(
                    relativePath: relativePath,
                    size: size,
                    modificationDate: values.contentModificationDate,
                    isReadableText: readability.isReadable,
                    readOnlyReason: readability.reason
                )
            )
        }

        return files.sorted { lhs, rhs in
            if lhs.relativePath == defaultSkillFileName { return true }
            if rhs.relativePath == defaultSkillFileName { return false }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    public static func loadSkillFile(skillName: String, relativePath: String) -> String? {
        guard let fileURL = resolveSkillFile(skillName: skillName, relativePath: relativePath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    public static func loadSkillTextResource(skillName: String, relativePath: String) throws -> String {
        guard let normalizedPath = SkillResourcePolicy.normalizeRelativePath(relativePath) else {
            throw SkillStoreError.invalidPath
        }
        guard let fileURL = resolveSkillFile(skillName: skillName, relativePath: normalizedPath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SkillStoreError.fileNotFound
        }
        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else {
            throw SkillStoreError.invalidPath
        }
        let size = Int64(values.fileSize ?? 0)
        let candidate = SkillResourcePolicy.candidateTextReadability(relativePath: normalizedPath, size: size)
        guard candidate.canAttemptRead else {
            throw SkillStoreError.saveFailed(candidate.reason ?? "该技能资源不能作为文本读取。")
        }
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw SkillStoreError.saveFailed("该技能资源不是 UTF-8 文本：\(normalizedPath)")
        }
    }

    public static func saveSkillFile(skillName: String, relativePath: String, content: String) -> Bool {
        guard let fileURL = resolveSkillFile(skillName: skillName, relativePath: relativePath) else { return false }
        do {
            try fileURL.deletingLastPathComponent().createDirectoryIfNeeded()
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            skillStoreLogger.error("保存技能文件失败 \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func deleteSkillFile(skillName: String, relativePath: String) -> Bool {
        guard relativePath != defaultSkillFileName else { return false }
        guard let fileURL = resolveSkillFile(skillName: skillName, relativePath: relativePath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            skillStoreLogger.error("删除技能文件失败 \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func saveSkill(name: String, content: String) -> SkillMetadata? {
        guard SkillPaths.isValidSkillName(name) else { return nil }
        let files = [defaultSkillFileName: content]
        guard saveSkillFilesAtomically(skillName: name, files: files) else { return nil }
        return listSkills().first(where: { $0.name == name })
    }

    public static func deleteSkill(name: String) -> Bool {
        guard let skillDir = resolveSkillDir(skillName: name),
              FileManager.default.fileExists(atPath: skillDir.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: skillDir)
            return true
        } catch {
            skillStoreLogger.error("删除技能目录失败 \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func saveSkillFilesAtomically(skillName: String, files: [String: String]) -> Bool {
        let dataFiles = files.reduce(into: [String: Data]()) { result, element in
            result[element.key] = Data(element.value.utf8)
        }
        return saveSkillDataFilesAtomically(skillName: skillName, files: dataFiles)
    }

    public static func saveSkillDataFilesAtomically(skillName: String, files: [String: Data]) -> Bool {
        let root = setupDirectoryIfNeeded()
        guard let targetDir = SkillPaths.resolveSkillDir(skillsRoot: root, skillName: skillName) else {
            return false
        }
        guard files.keys.contains(defaultSkillFileName) else { return false }
        guard let skillFileData = files[defaultSkillFileName],
              String(data: skillFileData, encoding: .utf8) != nil else {
            return false
        }

        let fm = FileManager.default
        guard let stagingDir = createTempSkillDir(root: root, skillName: skillName, suffix: "staging") else {
            return false
        }
        var backupDir: URL?

        defer {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
            if let backupDir, fm.fileExists(atPath: backupDir.path), fm.fileExists(atPath: targetDir.path) {
                try? fm.removeItem(at: backupDir)
            }
        }

        do {
            for (relativePath, data) in files {
                guard let target = SkillPaths.resolveSkillFile(skillDir: stagingDir, relativePath: relativePath) else {
                    return false
                }
                try target.deletingLastPathComponent().createDirectoryIfNeeded()
                try data.write(to: target, options: .atomic)
            }

            let stagingSkillFile = stagingDir.appendingPathComponent(defaultSkillFileName, isDirectory: false)
            guard fm.fileExists(atPath: stagingSkillFile.path) else { return false }

            if fm.fileExists(atPath: targetDir.path) {
                guard let backup = createTempSkillDir(root: root, skillName: skillName, suffix: "backup") else {
                    return false
                }
                backupDir = backup
                try fm.moveItem(at: targetDir, to: backup)
            }

            do {
                try fm.moveItem(at: stagingDir, to: targetDir)
            } catch {
                if let backupDir, !fm.fileExists(atPath: targetDir.path) {
                    try? fm.moveItem(at: backupDir, to: targetDir)
                }
                throw error
            }

            if let backupDir, fm.fileExists(atPath: backupDir.path) {
                try? fm.removeItem(at: backupDir)
            }
            return true
        } catch {
            skillStoreLogger.error("原子保存技能失败 \(skillName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func resolveSkillDir(skillName: String) -> URL? {
        let root = setupDirectoryIfNeeded()
        return SkillPaths.resolveSkillDir(skillsRoot: root, skillName: skillName)
    }

    public static func resolveSkillFile(skillName: String, relativePath: String) -> URL? {
        guard let skillDir = resolveSkillDir(skillName: skillName) else { return nil }
        return SkillPaths.resolveSkillFile(skillDir: skillDir, relativePath: relativePath)
    }

    // MARK: - Sync

    public static func exportSkillBundles() -> [SyncedSkillBundle] {
        let skills = listSkills()
        var bundles: [SyncedSkillBundle] = []
        for skill in skills {
            guard let filesMap = readAllSkillFileData(skillName: skill.name), !filesMap.isEmpty else { continue }
            let files = filesMap
                .map { SyncedSkillFile(relativePath: $0.key, data: $0.value) }
                .sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
            bundles.append(SyncedSkillBundle(name: skill.name, files: files))
        }
        return bundles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func readAllSkillFileData(skillName: String) -> [String: Data]? {
        guard let skillDir = resolveSkillDir(skillName: skillName),
              FileManager.default.fileExists(atPath: skillDir.path) else {
            return nil
        }
        let fileRefs = listSkillFiles(skillName: skillName)
        var files: [String: Data] = [:]
        for fileRef in fileRefs {
            guard let fileURL = SkillPaths.resolveSkillFile(skillDir: skillDir, relativePath: fileRef.relativePath),
                  let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            files[fileRef.relativePath] = data
        }
        return files
    }

    public static func readAllSkillFiles(skillName: String) -> [String: String]? {
        guard let skillDir = resolveSkillDir(skillName: skillName),
              FileManager.default.fileExists(atPath: skillDir.path) else {
            return nil
        }
        let fileRefs = listSkillFiles(skillName: skillName)
        var files: [String: String] = [:]
        for fileRef in fileRefs {
            guard let fileURL = SkillPaths.resolveSkillFile(skillDir: skillDir, relativePath: fileRef.relativePath),
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return nil
            }
            files[fileRef.relativePath] = content
        }
        return files
    }

    private static func parseMetadata(from skillFile: URL) -> SkillMetadata? {
        guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let fallbackName = skillFile.deletingLastPathComponent().lastPathComponent
        guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: fallbackName) else {
            return nil
        }

        let updateTime = ((try? skillFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? Date()
        return SkillMetadata(
            name: manifest.name,
            description: manifest.description,
            compatibility: manifest.compatibility,
            allowedTools: manifest.allowedTools,
            updatedAt: updateTime
        )
    }

    private static func textReadability(fileURL: URL, relativePath: String, size: Int64) -> (isReadable: Bool, reason: String?) {
        let candidate = SkillResourcePolicy.candidateTextReadability(relativePath: relativePath, size: size)
        guard candidate.canAttemptRead else {
            return (false, candidate.reason)
        }
        if SkillResourcePolicy.isKnownTextPath(relativePath) {
            return (true, nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return (false, NSLocalizedString("无法读取文件", comment: "Skill resource unreadable reason"))
        }
        return String(data: data, encoding: .utf8) != nil
            ? (true, nil)
            : (false, NSLocalizedString("非 UTF-8 文本资源，仅列出不读取", comment: "Skill resource unreadable reason"))
    }

    private static func createTempSkillDir(root: URL, skillName: String, suffix: String) -> URL? {
        let fm = FileManager.default
        for attempt in 0..<100 {
            let candidate = root.appendingPathComponent(".\(skillName).\(suffix).\(attempt).tmp", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                do {
                    try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
                    return candidate
                } catch {
                    continue
                }
            }
        }
        return nil
    }
}

private extension URL {
    func createDirectoryIfNeeded() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(at: self, withIntermediateDirectories: true)
        }
    }
}
