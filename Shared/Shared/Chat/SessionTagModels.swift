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
