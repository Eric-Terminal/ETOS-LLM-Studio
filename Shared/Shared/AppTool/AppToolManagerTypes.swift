// ============================================================================
// AppToolManagerTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具管理器共用的通知名、数据库枚举、目录项与错误类型。
// ============================================================================

import Foundation

public extension Notification.Name {
    static let appToolFillUserInputRequested = Notification.Name("com.ETOS.LLM.Studio.appTool.fillUserInput")
    static let appToolAskUserInputRequested = Notification.Name("com.ETOS.LLM.Studio.appTool.askUserInput")
}

public enum AppToolSQLiteDatabase: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chat
    case config
    case memory

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat:
            return "聊天"
        case .config:
            return "配置"
        case .memory:
            return "记忆"
        }
    }
}

public struct AppToolCatalogItem: Identifiable, Equatable, Sendable {
    public let kind: AppToolKind
    public let isEnabled: Bool

    public var id: AppToolKind { kind }

    public init(kind: AppToolKind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

public enum AppToolApprovalPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case askEveryTime = "ask_every_time"
    case alwaysAllow = "always_allow"
    case alwaysDeny = "always_deny"

    public var displayName: String {
        switch self {
        case .askEveryTime:
            return NSLocalizedString("每次询问", comment: "Ask every time approval policy")
        case .alwaysAllow:
            return NSLocalizedString("总是允许", comment: "Always allow approval policy")
        case .alwaysDeny:
            return NSLocalizedString("始终拒绝", comment: "Always deny approval policy")
        }
    }
}

public enum AppToolExecutionError: LocalizedError {
    case toolGroupDisabled
    case toolDisabled(String)
    case toolDeniedByPolicy(String)
    case unknownTool
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .toolGroupDisabled:
            return NSLocalizedString("拓展工具总开关已关闭。", comment: "App tools group disabled")
        case .toolDisabled(let name):
            return String(
                format: NSLocalizedString("拓展工具“%@”当前未启用。", comment: "App tool disabled"),
                name
            )
        case .toolDeniedByPolicy(let name):
            return String(
                format: NSLocalizedString("拓展工具“%@”当前审批策略为始终拒绝。", comment: "App tool denied by approval policy"),
                name
            )
        case .unknownTool:
            return NSLocalizedString("未找到对应的拓展工具。", comment: "Unknown app tool")
        case .invalidArguments(let message):
            return message
        }
    }
}
