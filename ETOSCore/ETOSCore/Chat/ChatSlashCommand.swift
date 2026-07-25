// ============================================================================
// ChatSlashCommand.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义聊天输入框可识别的斜杠命令，以及不改变普通消息语义的解析规则。
// ============================================================================

import Foundation

public enum ChatSlashCommand: String, CaseIterable, Hashable, Identifiable, Sendable {
    // 展示顺序按常用程度排列，不按字母排序。
    case new
    case model
    case sessions
    case settings
    case tools
    case daily
    case usage
    case memory
    case mcp
    case skills
    case shortcuts
    case roleplay
    case worldbook
    case features
    case temporary
    case compact
    case retry
    case stop
    case clear

    public var id: String { rawValue }

    public var invocation: String {
        "/\(rawValue)"
    }

    public var aliases: [String] {
        switch self {
        case .sessions:
            return ["history"]
        case .tools:
            return ["tool"]
        case .daily:
            return ["pulse"]
        case .usage:
            return ["stats"]
        case .skills:
            return ["skill"]
        case .features:
            return ["extensions"]
        case .temporary:
            return ["temp"]
        case .compact:
            return ["compress"]
        default:
            return []
        }
    }

    public var titleLocalizationKey: String {
        switch self {
        case .new:
            return "开启新对话"
        case .model:
            return "选择模型"
        case .sessions:
            return "历史会话管理"
        case .settings:
            return "设置"
        case .tools:
            return "工具中心"
        case .daily:
            return "每日脉冲"
        case .usage:
            return "用量统计"
        case .memory:
            return "记忆系统"
        case .mcp:
            return "MCP 工具集成"
        case .skills:
            return "Agent Skills"
        case .shortcuts:
            return "快捷指令工具集成"
        case .roleplay:
            return "角色扮演与酒馆兼容"
        case .worldbook:
            return "世界书"
        case .features:
            return "拓展功能"
        case .temporary:
            return "临时对话"
        case .compact:
            return "压缩为续聊"
        case .retry:
            return "重试"
        case .stop:
            return "停止生成"
        case .clear:
            return "清空输入"
        }
    }

    public var systemImage: String {
        switch self {
        case .new:
            return "plus.message"
        case .model:
            return "cpu"
        case .sessions:
            return "clock"
        case .settings:
            return "gearshape"
        case .tools:
            return "wrench"
        case .daily:
            return "sparkles"
        case .usage:
            return "chart.bar"
        case .memory:
            return "brain"
        case .mcp:
            return "network"
        case .skills:
            return "star"
        case .shortcuts:
            return "bolt"
        case .roleplay:
            return "theatermasks"
        case .worldbook:
            return "book"
        case .features:
            return "ellipsis.circle"
        case .temporary:
            return "eye.slash"
        case .compact:
            return "rectangle.compress.vertical"
        case .retry:
            return "arrow.clockwise"
        case .stop:
            return "stop.fill"
        case .clear:
            return "trash"
        }
    }
}

public enum ChatSlashCommandParser {
    /// 只识别完整且不带参数的命令；未知命令必须继续作为普通消息发送。
    public static func recognizedCommand(in text: String) -> ChatSlashCommand? {
        guard text.first == "/" else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }

        let token = String(trimmed.dropFirst())
        guard !token.isEmpty,
              !token.contains(where: \.isWhitespace) else {
            return nil
        }

        let normalizedToken = token.lowercased()
        return ChatSlashCommand.allCases.first { command in
            command.rawValue == normalizedToken || command.aliases.contains(normalizedToken)
        }
    }

    /// 建议只按界面展示的规范命令名匹配；别名仅供完整输入识别，避免候选名称与输入前缀不一致。
    public static func suggestions(for text: String) -> [ChatSlashCommand] {
        guard text.first == "/" else { return [] }
        let query = String(text.dropFirst())
        guard !query.contains(where: \.isWhitespace),
              !query.contains("/") else {
            return []
        }

        let normalizedQuery = query.lowercased()
        guard !normalizedQuery.isEmpty else {
            return ChatSlashCommand.allCases
        }

        return ChatSlashCommand.allCases.filter {
            $0.rawValue.hasPrefix(normalizedQuery)
        }
    }
}
