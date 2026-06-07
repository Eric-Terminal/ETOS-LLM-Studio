// ============================================================================
// SessionTagModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 会话标签模型：标签是独立实体，颜色只是标签属性。
// ============================================================================

import Foundation

public enum SessionTagColor: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .red:
            return NSLocalizedString("红色", comment: "Session tag color")
        case .orange:
            return NSLocalizedString("橙色", comment: "Session tag color")
        case .yellow:
            return NSLocalizedString("黄色", comment: "Session tag color")
        case .green:
            return NSLocalizedString("绿色", comment: "Session tag color")
        case .blue:
            return NSLocalizedString("蓝色", comment: "Session tag color")
        case .purple:
            return NSLocalizedString("紫色", comment: "Session tag color")
        case .gray:
            return NSLocalizedString("灰色", comment: "Session tag color")
        }
    }
}

public struct SessionTag: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: SessionTagColor?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        color: SessionTagColor? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.updatedAt = updatedAt
    }
}

public extension SessionTag {
    static func systemColorTagID(for color: SessionTagColor) -> UUID {
        switch color {
        case .red:
            return UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        case .orange:
            return UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        case .yellow:
            return UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        case .green:
            return UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        case .blue:
            return UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
        case .purple:
            return UUID(uuidString: "00000000-0000-4000-8000-000000000006")!
        case .gray:
            return UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
        }
    }

    static var systemColorTagIDs: Set<UUID> {
        Set(SessionTagColor.allCases.map { systemColorTagID(for: $0) })
    }

    static func systemColorTag(for color: SessionTagColor, updatedAt: Date = Date()) -> SessionTag {
        SessionTag(
            id: systemColorTagID(for: color),
            name: color.localizedName,
            color: color,
            updatedAt: updatedAt
        )
    }

    var systemColor: SessionTagColor? {
        guard let color, id == Self.systemColorTagID(for: color) else { return nil }
        return color
    }

    var isSystemColorTag: Bool {
        systemColor != nil
    }
}
