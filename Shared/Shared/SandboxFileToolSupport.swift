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

public enum SandboxFileToolError: LocalizedError {
    case invalidPath
    case escapedSandbox
    case directoryExpected(String)
    case fileExpected(String)
    case fileNotFound(String)
    case unsupportedEncoding(String)
    case writeFailed(String)

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
}
