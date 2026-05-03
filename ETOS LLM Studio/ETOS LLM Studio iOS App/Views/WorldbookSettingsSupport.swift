// ============================================================================
// WorldbookSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 iOS 世界书设置页共享的标签、文本规范化与导出文档辅助。
// ============================================================================

import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Shared

func worldbookPositionLabel(_ position: WorldbookPosition) -> String {
    switch position {
    case .before:
        return NSLocalizedString("系统前置", comment: "Worldbook position before")
    case .after:
        return NSLocalizedString("系统后置", comment: "Worldbook position after")
    case .anTop:
        return NSLocalizedString("AN 顶部", comment: "Worldbook position anTop")
    case .anBottom:
        return NSLocalizedString("AN 底部", comment: "Worldbook position anBottom")
    case .atDepth:
        return NSLocalizedString("按深度插入", comment: "Worldbook position atDepth")
    case .emTop:
        return NSLocalizedString("消息顶部", comment: "Worldbook position emTop")
    case .emBottom:
        return NSLocalizedString("消息底部", comment: "Worldbook position emBottom")
    case .outlet:
        return NSLocalizedString("Outlet", comment: "Worldbook position outlet")
    @unknown default:
        return NSLocalizedString("系统后置", comment: "Worldbook position fallback")
    }
}

func worldbookSelectiveLogicLabel(_ logic: WorldbookSelectiveLogic) -> String {
    switch logic {
    case .andAny:
        return NSLocalizedString("AND_ANY（任一命中）", comment: "Selective logic andAny")
    case .andAll:
        return NSLocalizedString("AND_ALL（全部命中）", comment: "Selective logic andAll")
    case .notAny:
        return NSLocalizedString("NOT_ANY（全部不命中）", comment: "Selective logic notAny")
    case .notAll:
        return NSLocalizedString("NOT_ALL（并非全部命中）", comment: "Selective logic notAll")
    @unknown default:
        return NSLocalizedString("AND_ANY（任一命中）", comment: "Selective logic fallback")
    }
}

func worldbookEntryRoleLabel(_ role: WorldbookEntryRole) -> String {
    switch role {
    case .system:
        return NSLocalizedString("系统", comment: "Worldbook role system")
    case .user:
        return NSLocalizedString("用户", comment: "Worldbook role user")
    case .assistant:
        return NSLocalizedString("助手", comment: "Worldbook role assistant")
    @unknown default:
        return NSLocalizedString("用户", comment: "Worldbook role default")
    }
}

extension String {
    func normalizedPlainQuotes() -> String {
        self
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "„", with: "\"")
            .replacingOccurrences(of: "‟", with: "\"")
            .replacingOccurrences(of: "＂", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‚", with: "'")
            .replacingOccurrences(of: "‛", with: "'")
            .replacingOccurrences(of: "＇", with: "'")
    }
}

struct WorldbookExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
