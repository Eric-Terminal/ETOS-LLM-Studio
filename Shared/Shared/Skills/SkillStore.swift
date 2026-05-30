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
        let normalizedPath = try normalizedReadablePath(relativePath)
        let resolved = try resolveReadableResource(
            skillName: skillName,
            normalizedPath: normalizedPath,
            enforceSizeLimit: true
        )
        return try loadResolvedTextResource(resolved)
    }

    public static func loadSkillReadableResource(skillName: String, relativePath: String) async throws -> String {
        let normalizedPath = try normalizedReadablePath(relativePath)
        let resolved = try resolveReadableResource(
            skillName: skillName,
            normalizedPath: normalizedPath,
            enforceSizeLimit: true
        )
        return try await loadResolvedReadableResource(resolved)
    }

    public static func loadSkillTextResourceChunk(
        skillName: String,
        relativePath: String,
        startLine: Int = 1,
        maxLines: Int = 200
    ) throws -> SkillTextResourceChunk {
        let normalizedPath = try normalizedReadablePath(relativePath)
        let resolved = try resolveReadableResource(
            skillName: skillName,
            normalizedPath: normalizedPath,
            enforceSizeLimit: requiresFullReadSizeLimit(relativePath: normalizedPath)
        )
        let content = try loadResolvedTextResource(resolved)
        return try makeResourceChunk(
            relativePath: normalizedPath,
            content: content,
            startLine: startLine,
            maxLines: maxLines
        )
    }

    public static func loadSkillReadableResourceChunk(
        skillName: String,
        relativePath: String,
        startLine: Int = 1,
        maxLines: Int = 200
    ) async throws -> SkillTextResourceChunk {
        let normalizedPath = try normalizedReadablePath(relativePath)
        let resolved = try resolveReadableResource(
            skillName: skillName,
            normalizedPath: normalizedPath,
            enforceSizeLimit: requiresFullReadSizeLimit(relativePath: normalizedPath)
        )
        let content = try await loadResolvedReadableResource(resolved)
        return try makeResourceChunk(
            relativePath: normalizedPath,
            content: content,
            startLine: startLine,
            maxLines: maxLines
        )
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
                try fm.removeItem(at: backup)
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

    public static func replaceSkillDataFilesAtomically(
        oldSkillName: String,
        newSkillName: String,
        files: [String: Data]
    ) -> Bool {
        let oldName = oldSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldName != newName else {
            return saveSkillDataFilesAtomically(skillName: newName, files: files)
        }

        let root = setupDirectoryIfNeeded()
        guard let oldDir = SkillPaths.resolveSkillDir(skillsRoot: root, skillName: oldName),
              let newDir = SkillPaths.resolveSkillDir(skillsRoot: root, skillName: newName),
              files.keys.contains(defaultSkillFileName),
              let skillFileData = files[defaultSkillFileName],
              String(data: skillFileData, encoding: .utf8) != nil else {
            return false
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) else {
            return false
        }
        guard let stagingDir = createTempSkillDir(root: root, skillName: newName, suffix: "staging") else {
            return false
        }
        var backupDir: URL?

        defer {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
            if let backupDir, fm.fileExists(atPath: backupDir.path), fm.fileExists(atPath: newDir.path) {
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

            guard let backup = createTempSkillDir(root: root, skillName: oldName, suffix: "backup") else {
                return false
            }
            backupDir = backup
            try fm.removeItem(at: backup)
            try fm.moveItem(at: oldDir, to: backup)
            do {
                try fm.moveItem(at: stagingDir, to: newDir)
            } catch {
                if !fm.fileExists(atPath: oldDir.path) {
                    try? fm.moveItem(at: backup, to: oldDir)
                }
                throw error
            }

            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
            }
            return true
        } catch {
            skillStoreLogger.error("替换技能目录失败 \(oldName, privacy: .public) -> \(newName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func skillExists(_ skillName: String) -> Bool {
        guard let skillDir = resolveSkillDir(skillName: skillName) else { return false }
        return FileManager.default.fileExists(atPath: skillDir.path)
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

    private struct ResolvedSkillResource {
        let relativePath: String
        let fileURL: URL
    }

    private static func normalizedReadablePath(_ relativePath: String) throws -> String {
        guard let normalizedPath = SkillResourcePolicy.normalizeRelativePath(relativePath) else {
            throw SkillStoreError.invalidPath
        }
        return normalizedPath
    }

    private static func resolveReadableResource(
        skillName: String,
        normalizedPath: String,
        enforceSizeLimit: Bool
    ) throws -> ResolvedSkillResource {
        guard let fileURL = resolveSkillFile(skillName: skillName, relativePath: normalizedPath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SkillStoreError.fileNotFound
        }
        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else {
            throw SkillStoreError.invalidPath
        }
        let size = Int64(values.fileSize ?? 0)
        let candidate = SkillResourcePolicy.candidateTextReadability(
            relativePath: normalizedPath,
            size: size,
            enforceSizeLimit: enforceSizeLimit
        )
        guard candidate.canAttemptRead else {
            throw SkillStoreError.saveFailed(candidate.reason ?? "该技能资源不能作为文本读取。")
        }
        return ResolvedSkillResource(relativePath: normalizedPath, fileURL: fileURL)
    }

    private static func requiresFullReadSizeLimit(relativePath: String) -> Bool {
        SkillResourcePolicy.isExtractableDocumentPath(relativePath)
            || SkillResourcePolicy.isImagePath(relativePath)
    }

    private static func loadResolvedTextResource(_ resource: ResolvedSkillResource) throws -> String {
        if SkillResourcePolicy.isExtractableDocumentPath(resource.relativePath) {
            return try extractSkillDocumentText(fileURL: resource.fileURL, relativePath: resource.relativePath)
        }
        return try extractSkillPlainText(fileURL: resource.fileURL, relativePath: resource.relativePath)
    }

    private static func loadResolvedReadableResource(_ resource: ResolvedSkillResource) async throws -> String {
        if SkillResourcePolicy.isExtractableDocumentPath(resource.relativePath) {
            return try extractSkillDocumentText(fileURL: resource.fileURL, relativePath: resource.relativePath)
        }
        if SkillResourcePolicy.isOCRImagePath(resource.relativePath) {
            return try await extractSkillImageText(fileURL: resource.fileURL, relativePath: resource.relativePath)
        }
        return try extractSkillPlainText(fileURL: resource.fileURL, relativePath: resource.relativePath)
    }

    private static func textReadability(fileURL: URL, relativePath: String, size: Int64) -> (isReadable: Bool, reason: String?) {
        let candidate = SkillResourcePolicy.candidateTextReadability(relativePath: relativePath, size: size)
        guard candidate.canAttemptRead else {
            if SkillResourcePolicy.normalizeRelativePath(relativePath) != nil,
               SkillResourcePolicy.isKnownTextPath(relativePath),
               size > SkillResourcePolicy.maxReadableTextBytes {
                return (true, NSLocalizedString("可分块读取", comment: "Skill resource chunk-readable marker"))
            }
            return (false, candidate.reason)
        }
        if SkillResourcePolicy.isKnownTextPath(relativePath) {
            return (true, nil)
        }
        if SkillResourcePolicy.isExtractableDocumentPath(relativePath) {
            return (true, nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return (false, NSLocalizedString("无法读取文件", comment: "Skill resource unreadable reason"))
        }
        if SkillResourcePolicy.isOCRImagePath(relativePath) {
            return isRecognizableImageData(data, relativePath: relativePath)
                ? (true, nil)
                : (false, NSLocalizedString("非 UTF-8 文本资源，仅列出不读取", comment: "Skill resource unreadable reason"))
        }
        return canExtractSkillPlainText(data: data, relativePath: relativePath)
            ? (true, nil)
            : (false, NSLocalizedString("非 UTF-8 文本资源，仅列出不读取", comment: "Skill resource unreadable reason"))
    }

    private static func extractSkillPlainText(fileURL: URL, relativePath: String) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SkillStoreError.saveFailed("无法读取技能资源：\(relativePath)")
        }
        do {
            return try FileAttachmentTextExtractor().extractText(from: makeAttachment(data: data, relativePath: relativePath))
        } catch {
            throw SkillStoreError.saveFailed(error.localizedDescription)
        }
    }

    private static func extractSkillDocumentText(fileURL: URL, relativePath: String) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SkillStoreError.saveFailed("无法读取技能资源：\(relativePath)")
        }
        do {
            return try FileAttachmentTextExtractor().extractText(from: makeAttachment(data: data, relativePath: relativePath))
        } catch {
            throw SkillStoreError.saveFailed(error.localizedDescription)
        }
    }

    private static func extractSkillImageText(fileURL: URL, relativePath: String) async throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SkillStoreError.saveFailed("无法读取技能资源：\(relativePath)")
        }
        guard isRecognizableImageData(data, relativePath: relativePath) else {
            throw SkillStoreError.saveFailed(NSLocalizedString("非 UTF-8 文本资源，仅列出不读取", comment: "Skill resource unreadable reason"))
        }
        do {
            return try await SystemImageOCRService.recognizeText(in: data)
        } catch {
            throw SkillStoreError.saveFailed(error.localizedDescription)
        }
    }

    private static func canExtractSkillPlainText(data: Data, relativePath: String) -> Bool {
        (try? FileAttachmentTextExtractor().extractText(from: makeAttachment(data: data, relativePath: relativePath))) != nil
    }

    private static func makeAttachment(data: Data, relativePath: String) -> FileAttachment {
        FileAttachment(
            data: data,
            mimeType: resolvedMimeType(for: relativePath),
            fileName: URL(fileURLWithPath: relativePath).lastPathComponent
        )
    }

    private static func resolvedMimeType(for relativePath: String) -> String {
        switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pdf":
            return "application/pdf"
        default:
            return "application/octet-stream"
        }
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

    private static func normalizedTextLines(_ content: String) -> [String] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func makeResourceChunk(
        relativePath: String,
        content: String,
        startLine: Int,
        maxLines: Int
    ) throws -> SkillTextResourceChunk {
        guard startLine >= 1, maxLines >= 1 else {
            throw SkillStoreError.saveFailed(NSLocalizedString("分块读取参数无效，请检查 start_line 和 max_lines。", comment: "Skill resource chunk invalid range"))
        }
        let lines = normalizedTextLines(content)
        let totalLines = lines.count
        guard totalLines > 0 else {
            return SkillTextResourceChunk(
                relativePath: relativePath,
                startLine: 1,
                endLine: 0,
                totalLines: 0,
                hasMore: false,
                content: ""
            )
        }
        guard startLine <= totalLines else {
            throw SkillStoreError.saveFailed(NSLocalizedString("分块读取参数无效，请检查 start_line 和 max_lines。", comment: "Skill resource chunk invalid range"))
        }

        let resolvedMaxLines = min(maxLines, 1000)
        let startIndex = startLine - 1
        let endExclusive = min(startIndex + resolvedMaxLines, totalLines)
        let selected = Array(lines[startIndex..<endExclusive])
        return SkillTextResourceChunk(
            relativePath: relativePath,
            startLine: startLine,
            endLine: startLine + selected.count - 1,
            totalLines: totalLines,
            hasMore: endExclusive < totalLines,
            content: selected.joined(separator: "\n")
        )
    }

    private static func isRecognizableImageData(_ data: Data, relativePath: String) -> Bool {
        guard SkillResourcePolicy.isOCRImagePath(relativePath) else { return false }
        let bytes = Array(data.prefix(64))
        return hasPrefix([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], in: bytes)
            || hasPrefix([0xFF, 0xD8, 0xFF], in: bytes)
            || hasPrefix(Array("GIF87a".utf8), in: bytes)
            || hasPrefix(Array("GIF89a".utf8), in: bytes)
            || hasPrefix(Array("BM".utf8), in: bytes)
            || hasPrefix(Array("II*\0".utf8), in: bytes)
            || hasPrefix(Array("MM\0*".utf8), in: bytes)
            || isRecognizableWebP(bytes)
            || hasRecognizableISOImageBrand(bytes)
    }

    private static func hasPrefix(_ prefix: [UInt8], in bytes: [UInt8]) -> Bool {
        bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
    }

    private static func isRecognizableWebP(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 12
            && asciiString(bytes[0..<4]) == "RIFF"
            && asciiString(bytes[8..<12]) == "WEBP"
    }

    private static func hasRecognizableISOImageBrand(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12, asciiString(bytes[4..<8]) == "ftyp" else {
            return false
        }
        let imageBrands: Set<String> = [
            "avif",
            "heic",
            "heix",
            "hevc",
            "hevx",
            "heis",
            "hevm",
            "hevs",
            "mif1",
            "msf1"
        ]
        for start in stride(from: 8, through: bytes.count - 4, by: 4) {
            let brand = asciiString(bytes[start..<start + 4])
            if imageBrands.contains(brand) {
                return true
            }
        }
        return false
    }

    private static func asciiString(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
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
