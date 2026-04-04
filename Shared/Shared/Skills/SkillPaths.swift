// ============================================================================
// SkillPaths.swift
// ============================================================================
// Agent Skills 路径安全辅助
// - 规范技能目录名
// - 防止路径穿越与越界访问
// ============================================================================

import Foundation

public enum SkillPaths {
    private static let allowedNameRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
        options: []
    )

    public static func isValidSkillName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != ".", trimmed != ".." else { return false }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return allowedNameRegex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    public static func resolveSkillDir(skillsRoot: URL, skillName: String) -> URL? {
        let normalized = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSkillName(normalized) else { return nil }
        let target = skillsRoot.appendingPathComponent(normalized, isDirectory: true).standardizedFileURL
        let canonicalRoot = skillsRoot.standardizedFileURL.path
        guard target.path == canonicalRoot || target.path.hasPrefix(canonicalRoot + "/") else {
            return nil
        }
        return target
    }

    public static func resolveSkillFile(skillDir: URL, relativePath: String) -> URL? {
        let normalized = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard !normalized.hasPrefix("/") else { return nil }
        guard !normalized.contains("\\") else { return nil }
        guard !normalized.split(separator: "/").contains("..") else { return nil }

        let target = skillDir.appendingPathComponent(normalized, isDirectory: false).standardizedFileURL
        let canonicalRoot = skillDir.standardizedFileURL.path
        guard target.path == canonicalRoot || target.path.hasPrefix(canonicalRoot + "/") else {
            return nil
        }
        return target
    }
}
