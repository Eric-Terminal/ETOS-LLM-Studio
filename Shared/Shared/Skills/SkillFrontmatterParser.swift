// ============================================================================
// SkillFrontmatterParser.swift
// ============================================================================
// 解析 Skill 文档 frontmatter
// - 支持 name / description / compatibility / allowed-tools 等键
// - 支持提取正文 body（去除 frontmatter）
// ============================================================================

import Foundation

public enum SkillFrontmatterParser {
    private static let frontmatterEndRegex = try! NSRegularExpression(pattern: #"\r?\n---(?:\r?\n|$)"#, options: [])

    public static func parse(_ content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        guard let endRange = findFrontmatterEndRange(in: content) else { return [:] }
        let nsContent = content as NSString
        let yamlRange = NSRange(location: 3, length: max(0, endRange.location - 3))
        guard NSMaxRange(yamlRange) <= nsContent.length else { return [:] }

        let yaml = nsContent.substring(with: yamlRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var result: [String: String] = [:]
        for line in yaml.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let colonIndex = text.firstIndex(of: ":") else { continue }
            let key = text[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = text[text.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    public static func extractBody(_ content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        guard let endRange = findFrontmatterEndRange(in: content) else { return content }
        let nsContent = content as NSString
        let start = endRange.location + endRange.length
        guard start <= nsContent.length else { return content }
        return nsContent.substring(from: start).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    private static func findFrontmatterEndRange(in content: String) -> NSRange? {
        let range = NSRange(location: 3, length: max(0, content.utf16.count - 3))
        return frontmatterEndRegex.firstMatch(in: content, options: [], range: range)?.range
    }
}
