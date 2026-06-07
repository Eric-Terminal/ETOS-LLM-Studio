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
            return NSLocalizedString("正文", comment: "Font semantic role title")
        case .emphasis:
            return NSLocalizedString("斜体", comment: "Font semantic role title")
        case .strong:
            return NSLocalizedString("粗体", comment: "Font semantic role title")
        case .code:
            return NSLocalizedString("代码", comment: "Font semantic role title")
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
            return NSLocalizedString("整段", comment: "Font fallback scope title")
        case .character:
            return NSLocalizedString("单字", comment: "Font fallback scope title")
        }
    }

    public var summary: String {
        switch self {
        case .segment:
            return NSLocalizedString("当前行为：一条文本里只要有字形缺失，就整段降级到下一优先级字体。", comment: "Font fallback segment summary")
        case .character:
            return NSLocalizedString("按单字回退：优先保留高优先级字体，缺失字形再由系统进行逐字回退。", comment: "Font fallback character summary")
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
            return NSLocalizedString("无法识别该字体文件。", comment: "Font import invalid data error")
        case .unsupportedFontFileExtension:
            return NSLocalizedString("仅支持导入 TTF / OTF / TTC / WOFF / WOFF2 字体文件。", comment: "Font import unsupported extension error")
        case .saveFailed:
            return NSLocalizedString("保存字体文件失败。", comment: "Font save failed error")
        case .deleteFailed:
            return NSLocalizedString("删除字体文件失败。", comment: "Font delete failed error")
        }
    }
}
