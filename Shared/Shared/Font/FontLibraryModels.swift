// ============================================================================
// FontLibraryModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 字体库的语义角色、资产记录、路由配置与错误类型。
// ============================================================================

import Foundation

public enum FontSemanticRole: String, Codable, CaseIterable, Identifiable {
    case body
    case emphasis
    case strong
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .body:
            return "正文"
        case .emphasis:
            return "斜体"
        case .strong:
            return "粗体"
        case .code:
            return "代码"
        }
    }
}

public enum FontFallbackScope: String, Codable, CaseIterable, Identifiable {
    case segment
    case character

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .segment:
            return "整段"
        case .character:
            return "单字"
        }
    }

    public var summary: String {
        switch self {
        case .segment:
            return "当前行为：一条文本里只要有字形缺失，就整段降级到下一优先级字体。"
        case .character:
            return "按单字回退：优先保留高优先级字体，缺失字形再由系统进行逐字回退。"
        }
    }
}

public struct FontAssetRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var fileName: String
    public var checksum: String
    public var displayName: String
    public var postScriptName: String
    public var importedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        fileName: String,
        checksum: String,
        displayName: String,
        postScriptName: String,
        importedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.fileName = fileName
        self.checksum = checksum
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.importedAt = importedAt
        self.isEnabled = isEnabled
    }
}

public struct FontRouteConfiguration: Codable, Equatable {
    public struct LanguageBucketConfiguration: Codable, Equatable {
        public var body: [UUID]
        public var emphasis: [UUID]
        public var strong: [UUID]
        public var code: [UUID]

        public init(
            body: [UUID] = [],
            emphasis: [UUID] = [],
            strong: [UUID] = [],
            code: [UUID] = []
        ) {
            self.body = body
            self.emphasis = emphasis
            self.strong = strong
            self.code = code
        }
    }

    public var body: [UUID]
    public var emphasis: [UUID]
    public var strong: [UUID]
    public var code: [UUID]
    public var languageBuckets: [String: LanguageBucketConfiguration]

    public init(
        body: [UUID] = [],
        emphasis: [UUID] = [],
        strong: [UUID] = [],
        code: [UUID] = [],
        languageBuckets: [String: LanguageBucketConfiguration] = [:]
    ) {
        self.body = body
        self.emphasis = emphasis
        self.strong = strong
        self.code = code
        self.languageBuckets = languageBuckets
    }

    public func chain(for role: FontSemanticRole) -> [UUID] {
        switch role {
        case .body:
            return body
        case .emphasis:
            return emphasis
        case .strong:
            return strong
        case .code:
            return code
        }
    }

    public mutating func setChain(_ ids: [UUID], for role: FontSemanticRole) {
        switch role {
        case .body:
            body = ids
        case .emphasis:
            emphasis = ids
        case .strong:
            strong = ids
        case .code:
            code = ids
        }
    }
}

public enum FontLibraryError: LocalizedError {
    case invalidFontData
    case unsupportedFontFileExtension
    case saveFailed
    case deleteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFontData:
            return "无法识别该字体文件。"
        case .unsupportedFontFileExtension:
            return "仅支持导入 TTF / OTF / TTC / WOFF / WOFF2 字体文件。"
        case .saveFailed:
            return "保存字体文件失败。"
        case .deleteFailed:
            return "删除字体文件失败。"
        }
    }
}
