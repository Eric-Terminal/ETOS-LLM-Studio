import Foundation

public enum WorldbookExportError: LocalizedError {
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "导出失败：无法序列化世界书数据。"
        }
    }
}

public struct WorldbookExportEnvelope: Codable, Sendable {
    public var version: Int
    public var type: String
    public var data: Worldbook

    public init(version: Int = 1, type: String = "lorebook", data: Worldbook) {
        self.version = version
        self.type = type
        self.data = data
    }
}

public struct WorldbookExportService {
    public init() {}

    public func exportWorldbook(_ worldbook: Worldbook) throws -> Data {
        let envelope = WorldbookExportEnvelope(data: worldbook)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(envelope)
        } catch {
            throw WorldbookExportError.encodeFailed
        }
    }

    public func suggestedFileName(for worldbook: Worldbook) -> String {
        let trimmed = worldbook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "worldbook" : trimmed
        let sanitized = sanitizeFileName(base)
        return "\(sanitized).lorebook.json"
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let collapsed = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "worldbook" : collapsed
    }
}
