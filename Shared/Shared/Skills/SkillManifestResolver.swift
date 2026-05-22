// ============================================================================
// SkillManifestResolver.swift
// ============================================================================
// 解析 Skill 元数据并兼容官方缺省规则
// - name 缺省时使用技能目录名
// - description 缺省时使用正文首段
// ============================================================================

import Foundation

public struct SkillManifestInfo: Sendable {
    public var name: String
    public var description: String
    public var compatibility: String?
    public var allowedTools: [String]

    public init(
        name: String,
        description: String,
        compatibility: String? = nil,
        allowedTools: [String] = []
    ) {
        self.name = name
        self.description = description
        self.compatibility = compatibility
        self.allowedTools = allowedTools
    }
}

public enum SkillManifestResolver {
    private static let paragraphSeparator = try! NSRegularExpression(pattern: #"\n\s*\n"#)

    public static func resolve(content: String, fallbackName: String?) throws -> SkillManifestInfo {
        let frontmatter = SkillFrontmatterParser.parse(content)
        let rawName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = (rawName?.isEmpty == false ? rawName : fallback),
              !name.isEmpty else {
            throw SkillStoreError.invalidSkillContent
        }
        guard SkillPaths.isValidSkillName(name) else {
            throw SkillStoreError.invalidSkillName
        }

        let rawDescription = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDescription = rawDescription?.isEmpty == false
            ? rawDescription!
            : (firstBodyParagraph(from: SkillFrontmatterParser.extractBody(content)) ?? name)
        let whenToUse = frontmatter["when_to_use"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = whenToUse?.isEmpty == false
            ? [baseDescription, whenToUse!].joined(separator: "\n")
            : baseDescription

        let compatibility = frontmatter["compatibility"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedTools = frontmatter["allowed-tools"]?
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        return SkillManifestInfo(
            name: name,
            description: description,
            compatibility: compatibility?.isEmpty == true ? nil : compatibility,
            allowedTools: allowedTools
        )
    }

    static func firstBodyParagraph(from body: String) -> String? {
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n")
        let nsBody = normalizedBody as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        var searchStart = 0

        for match in paragraphSeparator.matches(in: normalizedBody, options: [], range: fullRange) {
            if let paragraph = normalizedParagraph(from: nsBody.substring(with: NSRange(location: searchStart, length: match.range.location - searchStart))) {
                return paragraph
            }
            searchStart = match.range.location + match.range.length
        }

        guard searchStart <= nsBody.length else { return nil }
        return normalizedParagraph(from: nsBody.substring(from: searchStart))
    }

    private static func normalizedParagraph(from rawParagraph: String) -> String? {
        let trimmed = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("```") else {
            return nil
        }
        let paragraph = trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return paragraph.isEmpty ? nil : paragraph
    }
}
