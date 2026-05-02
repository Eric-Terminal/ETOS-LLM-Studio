// ============================================================================
// StorageBrowserSupport.swift
// ============================================================================
// 存储浏览辅助
//
// 提供目录相对路径展示与长文本分页能力，供 iOS/watchOS 存储管理界面复用。
// ============================================================================

import Foundation

public struct StorageTextPage: Identifiable, Hashable, Sendable {
    public let id: Int
    public let index: Int
    public let totalCount: Int
    public let startLineNumber: Int
    public let endLineNumber: Int
    public let content: String

    public init(
        index: Int,
        totalCount: Int,
        startLineNumber: Int,
        endLineNumber: Int,
        content: String
    ) {
        self.id = index
        self.index = index
        self.totalCount = totalCount
        self.startLineNumber = startLineNumber
        self.endLineNumber = endLineNumber
        self.content = content
    }
}

public enum StorageBrowserSupport {
    public static func relativeDisplayPath(
        for directory: URL,
        rootDirectory: URL
    ) -> String {
        let currentPath = directory.standardizedFileURL.path
        let rootPath = rootDirectory.standardizedFileURL.path

        guard currentPath.hasPrefix(rootPath) else {
            return directory.lastPathComponent
        }

        let relative = String(currentPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return relative.isEmpty ? "根目录" : relative
    }

    public static func isJSONFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json"
    }

    public static func paginateText(
        _ text: String,
        linesPerPage: Int = 100
    ) -> [StorageTextPage] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = rawLines.isEmpty ? [""] : rawLines
        let pageSize = max(1, linesPerPage)

        var pages: [StorageTextPage] = []
        let totalCount = Int(ceil(Double(lines.count) / Double(pageSize)))

        for pageIndex in 0..<totalCount {
            let start = pageIndex * pageSize
            let end = min(start + pageSize, lines.count)
            let content = lines[start..<end].joined(separator: "\n")
            pages.append(
                StorageTextPage(
                    index: pageIndex,
                    totalCount: totalCount,
                    startLineNumber: start + 1,
                    endLineNumber: end,
                    content: content
                )
            )
        }

        return pages
    }
}
