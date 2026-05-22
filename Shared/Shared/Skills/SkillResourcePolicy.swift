// ============================================================================
// SkillResourcePolicy.swift
// ============================================================================
// Agent Skills 资源读取策略
// - 允许模型读取技能包内的文本资源
// - 拒绝路径穿越、隐藏路径、过大文本和二进制资源
// - scripts/ 目录只允许读取内容，不提供执行能力
// ============================================================================

import Foundation

public enum SkillResourcePolicy {
    public static let maxReadableTextBytes: Int64 = 256 * 1024

    private static let readableExtensions: Set<String> = [
        "bash",
        "c",
        "cc",
        "conf",
        "cpp",
        "css",
        "csv",
        "env",
        "go",
        "graphql",
        "h",
        "hpp",
        "html",
        "ini",
        "js",
        "json",
        "jsonl",
        "jsx",
        "kt",
        "log",
        "lua",
        "m",
        "md",
        "mdx",
        "mm",
        "php",
        "plist",
        "properties",
        "proto",
        "py",
        "rb",
        "rs",
        "sh",
        "sql",
        "swift",
        "toml",
        "ts",
        "tsx",
        "txt",
        "xml",
        "yaml",
        "yml",
        "zsh"
    ]

    private static let readableFileNames: Set<String> = [
        "AGENTS.md",
        "Dockerfile",
        "Gemfile",
        "LICENSE",
        "Makefile",
        "Procfile",
        "README"
    ]

    public static func normalizeRelativePath(_ rawPath: String) -> String? {
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
            !component.isEmpty && component != "." && component != ".." && !component.hasPrefix(".")
        }) else {
            return nil
        }
        guard !hasURLScheme(normalized) else { return nil }
        return normalized
    }

    public static func canList(relativePath: String) -> Bool {
        normalizeRelativePath(relativePath) != nil
    }

    public static func candidateTextReadability(relativePath: String, size: Int64) -> (canAttemptRead: Bool, reason: String?) {
        guard normalizeRelativePath(relativePath) != nil else {
            return (false, NSLocalizedString("路径不合法", comment: "Skill resource unreadable reason"))
        }
        guard size <= maxReadableTextBytes else {
            return (false, NSLocalizedString("文件过大，仅列出不读取", comment: "Skill resource unreadable reason"))
        }
        return (true, nil)
    }

    public static func textReadability(relativePath: String, size: Int64) -> (isReadable: Bool, reason: String?) {
        let candidate = candidateTextReadability(relativePath: relativePath, size: size)
        guard candidate.canAttemptRead else {
            return (false, candidate.reason)
        }
        return isKnownTextPath(relativePath)
            ? (true, nil)
            : (false, NSLocalizedString("需读取时确认文本编码", comment: "Skill resource unreadable reason"))
    }

    public static func isKnownTextPath(_ relativePath: String) -> Bool {
        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
        if readableFileNames.contains(fileName) { return true }
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        return !ext.isEmpty && readableExtensions.contains(ext)
    }

    private static func hasURLScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
    }
}
