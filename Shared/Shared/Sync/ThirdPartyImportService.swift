// ============================================================================
// ThirdPartyImportService.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责第三方导入的公共入口与同步包组装。
// ============================================================================

import Foundation

public enum ThirdPartyImportSource: String, CaseIterable, Codable, Sendable {
    case etosBackup
    case cherryStudio
    case rikkahub
    case kelivo
    case chatgpt
    case chatbox

    public var displayName: String {
        switch self {
        case .etosBackup: return NSLocalizedString("ETOS 数据包", comment: "Third-party import source")
        case .cherryStudio: return "Cherry Studio"
        case .rikkahub: return "RikkaHub"
        case .kelivo: return "Kelivo"
        case .chatgpt: return "ChatGPT"
        case .chatbox: return "ChatBox"
        }
    }

    public var suggestedFileExtensions: [String] {
        switch self {
        case .etosBackup:
            return ["json"]
        case .cherryStudio:
            return ["json", "zip", "bak"]
        case .rikkahub:
            return ["json", "zip"]
        case .kelivo:
            return ["json", "zip"]
        case .chatgpt:
            return ["json"]
        case .chatbox:
            return ["json"]
        }
    }
}

public struct ThirdPartyImportPreparedResult {
    public var source: ThirdPartyImportSource
    public var package: SyncPackage
    public var warnings: [String]

    public init(source: ThirdPartyImportSource, package: SyncPackage, warnings: [String] = []) {
        self.source = source
        self.package = package
        self.warnings = warnings
    }

    public var parsedProvidersCount: Int { package.providers.count }
    public var parsedSessionsCount: Int { package.sessions.count }
}

public struct ThirdPartyImportReport {
    public var source: ThirdPartyImportSource
    public var parsedProvidersCount: Int
    public var parsedSessionsCount: Int
    public var summary: SyncMergeSummary
    public var warnings: [String]

    public init(
        source: ThirdPartyImportSource,
        parsedProvidersCount: Int,
        parsedSessionsCount: Int,
        summary: SyncMergeSummary,
        warnings: [String] = []
    ) {
        self.source = source
        self.parsedProvidersCount = parsedProvidersCount
        self.parsedSessionsCount = parsedSessionsCount
        self.summary = summary
        self.warnings = warnings
    }
}

public enum ThirdPartyImportError: LocalizedError {
    case fileNotReadable
    case invalidJSON
    case unsupportedBackupFormat(reason: String)
    case noImportableContent

    public var errorDescription: String? {
        switch self {
        case .fileNotReadable:
            return NSLocalizedString("无法读取所选文件。", comment: "")
        case .invalidJSON:
            return NSLocalizedString("文件不是有效的 JSON 数据。", comment: "")
        case .unsupportedBackupFormat(let reason):
            return reason
        case .noImportableContent:
            return NSLocalizedString("未解析到可导入的提供商或会话。", comment: "")
        }
    }
}

public enum ThirdPartyImportService {
    public static func prepareImport(
        source: ThirdPartyImportSource,
        fileURL: URL
    ) throws -> ThirdPartyImportPreparedResult {
        try withSecurityScopedAccess(to: fileURL) {
            if source == .etosBackup {
                let package = try parseETOSBackup(fileURL: fileURL)
                return ThirdPartyImportPreparedResult(
                    source: source,
                    package: package,
                    warnings: []
                )
            }

            let parsed: ParsedPayload
            switch source {
            case .cherryStudio:
                parsed = try parseCherryStudio(fileURL: fileURL)
            case .rikkahub:
                parsed = try parseRikkaHub(fileURL: fileURL)
            case .kelivo:
                parsed = try parseKelivo(fileURL: fileURL)
            case .chatgpt:
                parsed = try parseChatGPT(fileURL: fileURL)
            case .chatbox:
                parsed = try parseChatBox(fileURL: fileURL)
            case .etosBackup:
                // 已在前置分支返回，这里仅为穷尽匹配。
                throw ThirdPartyImportError.unsupportedBackupFormat(reason: NSLocalizedString("导入来源未实现。", comment: "Third-party import unsupported source error"))
            }

            let package = try makePackage(from: parsed)
            return ThirdPartyImportPreparedResult(
                source: source,
                package: package,
                warnings: parsed.warnings
            )
        }
    }

    @discardableResult
    public static func importAndApply(
        source: ThirdPartyImportSource,
        fileURL: URL,
        chatService: ChatService = .shared,
        memoryManager: MemoryManager? = nil,
        userDefaults: UserDefaults = .standard
    ) async throws -> ThirdPartyImportReport {
        let prepared = try prepareImport(source: source, fileURL: fileURL)
        let summary = await SyncEngine.apply(
            package: prepared.package,
            chatService: chatService,
            memoryManager: memoryManager,
            userDefaults: userDefaults
        )
        return ThirdPartyImportReport(
            source: source,
            parsedProvidersCount: prepared.parsedProvidersCount,
            parsedSessionsCount: prepared.parsedSessionsCount,
            summary: summary,
            warnings: prepared.warnings
        )
    }
}

extension ThirdPartyImportService {
    struct ParsedPayload {
        var providers: [Provider]
        var sessions: [SyncedSession]
        var warnings: [String]
    }

    static func makePackage(from parsed: ParsedPayload) throws -> SyncPackage {
        var options: SyncOptions = []
        if !parsed.providers.isEmpty {
            options.insert(.providers)
        }
        if !parsed.sessions.isEmpty {
            options.insert(.sessions)
        }
        guard !options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }
        return SyncPackage(
            options: options,
            providers: parsed.providers,
            sessions: parsed.sessions
        )
    }
}
