// ============================================================================
// SandboxFileToolSupport.swift
// ============================================================================
// 沙盒文件工具辅助。
// - 仅允许访问 Documents 根目录及其子路径
// - 提供列目录、读文本、写文本能力
// ============================================================================

import Foundation

public struct SandboxFileEntry: Codable, Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: String?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: String?
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct SandboxFileWriteResult: Codable, Hashable, Sendable {
    public let path: String
    public let size: Int64
    public let createdParentDirectories: Bool

    public init(path: String, size: Int64, createdParentDirectories: Bool) {
        self.path = path
        self.size = size
        self.createdParentDirectories = createdParentDirectories
    }
}

public struct SandboxFileEditResult: Codable, Hashable, Sendable {
    public let path: String
    public let replacements: Int
    public let size: Int64

    public init(path: String, replacements: Int, size: Int64) {
        self.path = path
        self.replacements = replacements
        self.size = size
    }
}

public struct SandboxFileDeleteResult: Codable, Hashable, Sendable {
    public let path: String
    public let wasDirectory: Bool

    public init(path: String, wasDirectory: Bool) {
        self.path = path
        self.wasDirectory = wasDirectory
    }
}

public enum SandboxFileToolError: LocalizedError {
    case invalidPath
    case escapedSandbox
    case directoryExpected(String)
    case fileExpected(String)
    case fileNotFound(String)
    case unsupportedEncoding(String)
    case writeFailed(String)
    case emptyMatchText
    case oldTextNotFound
    case ambiguousMatch(count: Int)
    case deletingRootDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return NSLocalizedString("文件路径无效。", comment: "Sandbox tool invalid path")
        case .escapedSandbox:
            return NSLocalizedString("不允许访问沙盒外部路径。", comment: "Sandbox tool escaped sandbox")
        case .directoryExpected(let path):
            return String(
                format: NSLocalizedString("路径“%@”不是目录。", comment: "Sandbox tool directory expected"),
                path
            )
        case .fileExpected(let path):
            return String(
                format: NSLocalizedString("路径“%@”是目录，不能按文件读取。", comment: "Sandbox tool file expected"),
                path
            )
        case .fileNotFound(let path):
            return String(
                format: NSLocalizedString("未找到文件“%@”。", comment: "Sandbox tool file not found"),
                path
            )
        case .unsupportedEncoding(let path):
            return String(
                format: NSLocalizedString("文件“%@”不是 UTF-8 文本，当前工具无法直接读取。", comment: "Sandbox tool unsupported encoding"),
                path
            )
        case .writeFailed(let message):
            return message
        case .emptyMatchText:
            return NSLocalizedString("要替换的旧文本不能为空。", comment: "Sandbox tool empty match text")
        case .oldTextNotFound:
            return NSLocalizedString("未在文件中找到要替换的旧文本。", comment: "Sandbox tool old text not found")
        case .ambiguousMatch(let count):
            return String(
                format: NSLocalizedString("旧文本在文件中出现了 %d 次，请改用 replace_all 或提供更精确的片段。", comment: "Sandbox tool ambiguous match"),
                count
            )
        case .deletingRootDirectory:
            return NSLocalizedString("不允许删除 Documents 根目录。", comment: "Sandbox tool deleting root directory")
        }
    }
}

public enum SandboxFileToolSupport {
    public static func listDirectory(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> [SandboxFileEntry] {
        let directoryURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory))
        }
        guard isDirectory.boolValue else {
            throw SandboxFileToolError.directoryExpected(normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory))
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let formatter = ISO8601DateFormatter()
        return contents.compactMap { url in
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return SandboxFileEntry(
                    path: normalizedDisplayPath(for: url, rootDirectory: rootDirectory),
                    name: url.lastPathComponent,
                    isDirectory: values.isDirectory ?? false,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate.map(formatter.string(from:))
                )
            } catch {
                return nil
            }
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func readTextFile(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> String {
        let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }
        guard !isDirectory.boolValue else {
            throw SandboxFileToolError.fileExpected(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SandboxFileToolError.unsupportedEncoding(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }
        return content
    }

    public static func writeTextFile(
        relativePath: String,
        content: String,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileWriteResult {
        let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        let parentDirectory = fileURL.deletingLastPathComponent()

        var isDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory)
        var createdDirectories = false

        if parentExists {
            guard isDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法写入文件。", comment: "Sandbox tool parent path not directory"),
                        normalizedDisplayPath(for: parentDirectory, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if createIntermediateDirectories {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            createdDirectories = true
        } else {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox tool parent missing"),
                    normalizedDisplayPath(for: parentDirectory, rootDirectory: rootDirectory)
                )
            )
        }

        let data = Data(content.utf8)
        do {
            try data.write(to: fileURL, options: [.atomic])
            StorageUtility.notifyFilesystemMutation(at: fileURL)
            return SandboxFileWriteResult(
                path: normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory),
                size: Int64(data.count),
                createdParentDirectories: createdDirectories
            )
        } catch {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("写入文件“%@”失败：%@", comment: "Sandbox tool write failed"),
                    normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory),
                    error.localizedDescription
                )
            )
        }
    }

    public static func diffTextFile(
        relativePath: String,
        updatedContent: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> String {
        let currentContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        let diff = simpleUnifiedDiff(
            original: currentContent,
            updated: updatedContent
        )
        return diff.isEmpty
            ? NSLocalizedString("内容没有变化。", comment: "Sandbox diff no changes")
            : diff
    }

    public static func replaceText(
        relativePath: String,
        oldText: String,
        newText: String,
        replaceAll: Bool = false,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileEditResult {
        let currentContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        guard !oldText.isEmpty else {
            throw SandboxFileToolError.emptyMatchText
        }

        let matchCount = occurrenceCount(of: oldText, in: currentContent)
        guard matchCount > 0 else {
            throw SandboxFileToolError.oldTextNotFound
        }
        if matchCount > 1 && !replaceAll {
            throw SandboxFileToolError.ambiguousMatch(count: matchCount)
        }

        let nextContent: String
        let replacements: Int
        if replaceAll {
            nextContent = currentContent.replacingOccurrences(of: oldText, with: newText)
            replacements = matchCount
        } else {
            nextContent = currentContent.replacingOccurrences(of: oldText, with: newText, options: [], range: currentContent.range(of: oldText))
            replacements = 1
        }

        let writeResult = try writeTextFile(
            relativePath: relativePath,
            content: nextContent,
            createIntermediateDirectories: true,
            rootDirectory: rootDirectory
        )
        return SandboxFileEditResult(
            path: writeResult.path,
            replacements: replacements,
            size: writeResult.size
        )
    }

    public static func deleteItem(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileDeleteResult {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Documents" || trimmed == "/" {
            throw SandboxFileToolError.deletingRootDirectory
        }

        let targetURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: targetURL, rootDirectory: rootDirectory))
        }

        try FileManager.default.removeItem(at: targetURL)
        StorageUtility.notifyFilesystemMutation(at: targetURL)
        return SandboxFileDeleteResult(
            path: normalizedDisplayPath(for: targetURL, rootDirectory: rootDirectory),
            wasDirectory: isDirectory.boolValue
        )
    }

    internal static func resolveURL(
        relativePath: String,
        rootDirectory: URL,
        allowRoot: Bool
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInput = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalizedInput.isEmpty {
            guard allowRoot else {
                throw SandboxFileToolError.invalidPath
            }
            return rootDirectory.standardizedFileURL
        }

        let strippedInput: String
        if normalizedInput == "Documents" {
            strippedInput = ""
        } else if normalizedInput.hasPrefix("Documents/") {
            strippedInput = String(normalizedInput.dropFirst("Documents/".count))
        } else {
            strippedInput = normalizedInput
        }

        let pathComponents = strippedInput
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !pathComponents.isEmpty else {
            guard allowRoot else {
                throw SandboxFileToolError.invalidPath
            }
            return rootDirectory.standardizedFileURL
        }

        guard !pathComponents.contains("..") else {
            throw SandboxFileToolError.escapedSandbox
        }

        let targetURL = pathComponents.reduce(rootDirectory) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL

        let rootPath = rootDirectory.standardizedFileURL.path
        let targetPath = targetURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw SandboxFileToolError.escapedSandbox
        }

        return targetURL
    }

    internal static func normalizedDisplayPath(
        for url: URL,
        rootDirectory: URL
    ) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path

        if targetPath == rootPath {
            return "Documents"
        }

        let relative = String(targetPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "Documents" : "Documents/\(relative)"
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func simpleUnifiedDiff(
        original: String,
        updated: String
    ) -> String {
        let originalLines = normalizeLines(original)
        let updatedLines = normalizeLines(updated)
        let difference = updatedLines.difference(from: originalLines)

        guard !difference.isEmpty else { return "" }

        let orderedChanges = difference.sorted { lhs, rhs in
            let lhsOffset: Int
            let rhsOffset: Int
            switch lhs {
            case .remove(let offset, _, _), .insert(let offset, _, _):
                lhsOffset = offset
            }
            switch rhs {
            case .remove(let offset, _, _), .insert(let offset, _, _):
                rhsOffset = offset
            }
            if lhsOffset == rhsOffset {
                switch (lhs, rhs) {
                case (.remove, .insert):
                    return true
                case (.insert, .remove):
                    return false
                default:
                    return true
                }
            }
            return lhsOffset < rhsOffset
        }

        var lines: [String] = ["--- current", "+++ proposed"]
        for change in orderedChanges {
            switch change {
            case .remove(let offset, let element, _):
                lines.append("@@ line \(offset + 1) @@")
                lines.append("-\(element)")
            case .insert(let offset, let element, _):
                lines.append("@@ line \(offset + 1) @@")
                lines.append("+\(element)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func normalizeLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
