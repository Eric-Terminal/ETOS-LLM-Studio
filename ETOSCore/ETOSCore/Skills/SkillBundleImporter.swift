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
        let fallbackName = suggestedSkillName(from: suggestedFileName)
        if suggestedFileName?.lowercased().hasSuffix(".zip") == true || isLikelyZipData(data) {
            return try importZipData(data, fallbackName: fallbackName)
        }
        if let content = String(data: data, encoding: .utf8) {
            return try makeResult(files: [SkillStore.defaultSkillFileName: Data(content.utf8)], fallbackName: fallbackName)
        }
        return try importZipData(data, fallbackName: fallbackName)
    }

    private static func importSingleSkillFile(_ fileURL: URL) throws -> SkillImportResult {
        let data = try Data(contentsOf: fileURL)
        return try makeResult(
            files: [SkillStore.defaultSkillFileName: data],
            fallbackName: fallbackNameForSingleSkillFile(fileURL)
        )
    }

    private static func importDirectory(_ directoryURL: URL) throws -> SkillImportResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw SkillStoreError.fileNotFound
        }

        var files: [String: Data] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            guard values.isDirectory != true else { continue }
            let relativePath = relativePath(for: fileURL, baseURL: directoryURL)
            guard let normalizedPath = normalizeSourceBundlePath(relativePath) else { continue }
            files[normalizedPath] = try Data(contentsOf: fileURL)
        }
        let normalized = normalizeBundleFiles(files, fallbackName: directoryURL.lastPathComponent)
        return try makeResult(files: normalized.files, fallbackName: normalized.fallbackName)
    }

    private static func importZip(_ fileURL: URL) throws -> SkillImportResult {
        let archive = try Archive(url: fileURL, accessMode: .read)
        return try importArchive(archive, fallbackName: suggestedSkillName(from: fileURL.lastPathComponent))
    }

    private static func importZipData(_ data: Data, fallbackName: String?) throws -> SkillImportResult {
        let archive = try Archive(data: data, accessMode: .read)
        return try importArchive(archive, fallbackName: fallbackName)
    }

    private static func importArchive(_ archive: Archive, fallbackName: String?) throws -> SkillImportResult {
        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            guard let normalizedPath = normalizeSourceBundlePath(entry.path) else { continue }
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
            files[normalizedPath] = data
        }
        let normalized = normalizeBundleFiles(files, fallbackName: fallbackName)
        return try makeResult(files: normalized.files, fallbackName: normalized.fallbackName)
    }

    private static func makeResult(files: [String: Data], fallbackName: String?) throws -> SkillImportResult {
        guard let skillData = files[SkillStore.defaultSkillFileName],
              let skillContent = String(data: skillData, encoding: .utf8) else {
            throw SkillStoreError.missingSkillFile
        }
        let manifest = try SkillManifestResolver.resolve(content: skillContent, fallbackName: fallbackName)
        return SkillImportResult(skillName: manifest.name, files: files)
    }

    private struct NormalizedBundleFiles {
        var files: [String: Data]
        var fallbackName: String?
    }

    private static func normalizeBundleFiles(_ files: [String: Data], fallbackName: String?) -> NormalizedBundleFiles {
        if files.keys.contains(SkillStore.defaultSkillFileName) {
            return NormalizedBundleFiles(files: safeSkillFiles(files), fallbackName: fallbackName)
        }
        let suffix = "/" + SkillStore.defaultSkillFileName
        let skillFilePaths = files.keys.filter { $0.hasSuffix(suffix) }
        guard skillFilePaths.count == 1, let skillFilePath = skillFilePaths.first else {
            return NormalizedBundleFiles(files: files, fallbackName: fallbackName)
        }
        let rootPath = String(skillFilePath.dropLast(suffix.count))
        let rootPrefix = rootPath + "/"
        let normalizedFiles = files.reduce(into: [String: Data]()) { result, element in
            guard element.key.hasPrefix(rootPrefix) else { return }
            let relativePath = String(element.key.dropFirst(rootPrefix.count))
            guard let normalizedPath = SkillResourcePolicy.normalizeRelativePath(relativePath) else { return }
            result[normalizedPath] = element.value
        }
        let rootName = rootPath.split(separator: "/").last.map(String.init)
        return NormalizedBundleFiles(files: normalizedFiles, fallbackName: rootName ?? fallbackName)
    }

    private static func safeSkillFiles(_ files: [String: Data]) -> [String: Data] {
        files.reduce(into: [String: Data]()) { result, element in
            guard let normalizedPath = SkillResourcePolicy.normalizeRelativePath(element.key) else { return }
            result[normalizedPath] = element.value
        }
    }

    private static func normalizeSourceBundlePath(_ rawPath: String) -> String? {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard normalized.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".."
        }) else {
            return nil
        }
        guard !hasURLScheme(normalized) else { return nil }
        return normalized
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

    private static func hasURLScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
    }

    private static func fallbackNameForSingleSkillFile(_ fileURL: URL) -> String? {
        if fileURL.lastPathComponent == SkillStore.defaultSkillFileName {
            let parentName = fileURL.deletingLastPathComponent().lastPathComponent
            return SkillPaths.isValidSkillName(parentName) ? parentName : nil
        }
        return suggestedSkillName(from: fileURL.lastPathComponent)
    }

    private static func suggestedSkillName(from fileName: String?) -> String? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let url = URL(fileURLWithPath: fileName)
        if url.lastPathComponent == SkillStore.defaultSkillFileName {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            return SkillPaths.isValidSkillName(parentName) ? parentName : nil
        }
        let name = url.deletingPathExtension().lastPathComponent
        return SkillPaths.isValidSkillName(name) ? name : nil
    }
}
