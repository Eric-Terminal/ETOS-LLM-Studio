// ============================================================================
// StorageUtilityModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 存储管理界面和清理工具共享的文件条目、分类与统计模型。
// ============================================================================

import Foundation
import SwiftUI

/// 文件信息模型
public struct FileItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let url: URL
    public let size: Int64
    public let modificationDate: Date
    public let isDirectory: Bool
    
    public init(url: URL, attributes: [FileAttributeKey: Any]) {
        self.id = url.path
        self.name = url.lastPathComponent
        self.url = url
        self.size = attributes[.size] as? Int64 ?? 0
        self.modificationDate = attributes[.modificationDate] as? Date ?? Date()
        self.isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
    }
}

/// 存储类别
public enum StorageCategory: String, CaseIterable, Identifiable {
    case sessions = "ChatSessions"
    case audio = "AudioFiles"
    case images = "ImageFiles"
    case memory = "Memory"
    case backgrounds = "Backgrounds"
    case config = "Config"
    case skills = "Skills"
    case shortcutTools = "ShortcutTools"
    case worldbooks = "Worldbooks"
    case localModels = "LocalModels"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .sessions: return NSLocalizedString("聊天会话", comment: "")
        case .audio: return NSLocalizedString("语音文件", comment: "")
        case .images: return NSLocalizedString("图片文件", comment: "")
        case .memory: return NSLocalizedString("记忆数据", comment: "")
        case .backgrounds: return NSLocalizedString("背景图片", comment: "")
        case .config: return NSLocalizedString("配置数据库", comment: "")
        case .skills: return NSLocalizedString("Agent Skills", comment: "")
        case .shortcutTools: return NSLocalizedString("快捷指令工具", comment: "")
        case .worldbooks: return NSLocalizedString("世界书", comment: "")
        case .localModels: return NSLocalizedString("本地模型", comment: "")
        }
    }
    
    public var systemImage: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .audio: return "waveform"
        case .images: return "photo.on.rectangle"
        case .memory: return "brain.head.profile"
        case .backgrounds: return "photo.artframe"
        case .config: return "gearshape.2"
        case .skills: return "sparkles.square.filled.on.square"
        case .shortcutTools: return "bolt.horizontal.circle"
        case .worldbooks: return "book.pages"
        case .localModels: return "cpu"
        }
    }
    
    public var iconColor: Color {
        switch self {
        case .sessions: return .blue
        case .audio: return .orange
        case .images: return .green
        case .memory: return .purple
        case .backgrounds: return .pink
        case .config: return .indigo
        case .skills: return .cyan
        case .shortcutTools: return .mint
        case .worldbooks: return .brown
        case .localModels: return .blue
        }
    }
}

/// 存储统计信息
public struct StorageBreakdown {
    public var totalSize: Int64 = 0
    public var categorySize: [StorageCategory: Int64] = [:]
    public var otherSize: Int64 = 0
    public var cacheSize: Int64 {
        (categorySize[.audio] ?? 0) + (categorySize[.images] ?? 0)
    }
    
    public init() {
        for category in StorageCategory.allCases {
            categorySize[category] = 0
        }
    }
}
