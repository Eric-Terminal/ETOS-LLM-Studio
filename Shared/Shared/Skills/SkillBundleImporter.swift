// ============================================================================
// SkillBundleImporter.swift
// ============================================================================
// Agent Skills 本地包导入器
// - 支持 SKILL.md 单文件、技能目录和 zip 技能包
// - 保留文本与二进制资源，但只接受安全相对路径
// ============================================================================

import Foundation
import ZIPFoundation

public enum SkillBundleImporter {
    public static func importSkill(from fileURL: URL) throws -> SkillImportResult {
        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            return try importDirectory(fileURL)
        }
        if fileURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame {
            return try importZip(fileURL)
        }
        return try importSingleSkillFile(fileURL)
    }

    public static func importSkill(fromDownloadedData data: Data, suggestedFileName: String?) throws -> SkillImportResult {
        if suggestedFileName?.lowercased().hasSuffix(".zip") == true || isLikelyZipData(data) {
            return try importZipData(data)
        }
        if let content = String(data: data, encoding: .utf8) {
            return try makeResult(files: [SkillStore.defaultSkillFileName: Data(content.utf8)])
        }
        return try importZipData(data)
    }

    private static func importSingleSkillFile(_ fileURL: URL) throws -> SkillImportResult {
        let data = try Data(contentsOf: fileURL)
        return try makeResult(files: [SkillStore.defaultSkillFileName: data])
    }

    private static func importDirectory(_ directoryURL: URL) throws -> SkillImportResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SkillStoreError.fileNotFound
        }

        var files: [String: Data] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            guard values.isDirectory != true else { continue }
            let relativePath = relativePath(for: fileURL, baseURL: directoryURL)
            guard let normalizedPath = SkillResourcePolicy.normalizeRelativePath(relativePath) else { continue }
            files[normalizedPath] = try Data(contentsOf: fileURL)
        }
        return try makeResult(files: flattenIfNeeded(files))
    }

    private static func importZip(_ fileURL: URL) throws -> SkillImportResult {
        let archive = try Archive(url: fileURL, accessMode: .read)
        return try importArchive(archive)
    }

    private static func importZipData(_ data: Data) throws -> SkillImportResult {
        let archive = try Archive(data: data, accessMode: .read)
        return try importArchive(archive)
    }

    private static func importArchive(_ archive: Archive) throws -> SkillImportResult {
        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            guard let normalizedPath = SkillResourcePolicy.normalizeRelativePath(entry.path) else { continue }
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
            files[normalizedPath] = data
        }
        return try makeResult(files: flattenIfNeeded(files))
    }

    private static func makeResult(files: [String: Data]) throws -> SkillImportResult {
        guard let skillData = files[SkillStore.defaultSkillFileName],
              let skillContent = String(data: skillData, encoding: .utf8) else {
            throw SkillStoreError.missingSkillFile
        }
        let frontmatter = SkillFrontmatterParser.parse(skillContent)
        guard let skillName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skillName.isEmpty else {
            throw SkillStoreError.invalidSkillContent
        }
        return SkillImportResult(skillName: skillName, files: files)
    }

    private static func flattenIfNeeded(_ files: [String: Data]) -> [String: Data] {
        if files.keys.contains(SkillStore.defaultSkillFileName) {
            return files
        }
        let suffix = "/" + SkillStore.defaultSkillFileName
        let skillFilePaths = files.keys.filter { $0.hasSuffix(suffix) }
        guard skillFilePaths.count == 1, let skillFilePath = skillFilePaths.first else {
            return files
        }
        let rootPrefix = String(skillFilePath.dropLast(suffix.count)) + "/"
        return files.reduce(into: [String: Data]()) { result, element in
            guard element.key.hasPrefix(rootPrefix) else { return }
            let relativePath = String(element.key.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { return }
            result[relativePath] = element.value
        }
    }

    private static func relativePath(for fileURL: URL, baseURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(basePath.count + 1))
    }

    private static func isLikelyZipData(_ data: Data) -> Bool {
        let signatures: [[UInt8]] = [
            [0x50, 0x4B, 0x03, 0x04],
            [0x50, 0x4B, 0x05, 0x06],
            [0x50, 0x4B, 0x07, 0x08]
        ]
        return signatures.contains { data.starts(with: $0) }
    }
}
