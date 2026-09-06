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
    case openMinis

    public var displayName: String {
        switch self {
        case .etosBackup: return NSLocalizedString("ETOS 数据包", comment: "Third-party import source")
        case .cherryStudio: return "Cherry Studio"
        case .rikkahub: return "RikkaHub"
        case .kelivo: return "Kelivo"
        case .chatgpt: return "ChatGPT"
        case .chatbox: return "ChatBox"
        case .openMinis: return "OpenMinis"
        }
    }

    public var suggestedFileExtensions: [String] {
        switch self {
        case .etosBackup:
            return [SnapshotBuilder.fileExtension, "json"]
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
        case .openMinis:
            return ["json", "zip"]
        }
    }
}

public struct ThirdPartyImportPreparedResult {
    public var source: ThirdPartyImportSource
    public var package: SyncPackage
    public var warnings: [String]
    public var recognizedSkillNames: [String]
    public var containsSensitiveCredentials: Bool
    public var parsedMessagesCount: Int
    public var attachmentPlaceholderCount: Int
    public var degradedItemCount: Int

    public init(
        source: ThirdPartyImportSource,
        package: SyncPackage,
        warnings: [String] = [],
        recognizedSkillNames: [String] = [],
        containsSensitiveCredentials: Bool = false,
        parsedMessagesCount: Int = 0,
        attachmentPlaceholderCount: Int = 0,
        degradedItemCount: Int = 0
    ) {
        self.source = source
        self.package = package
        self.warnings = warnings
        self.recognizedSkillNames = recognizedSkillNames
        self.containsSensitiveCredentials = containsSensitiveCredentials
        self.parsedMessagesCount = parsedMessagesCount
        self.attachmentPlaceholderCount = attachmentPlaceholderCount
        self.degradedItemCount = degradedItemCount
    }

    public var parsedProvidersCount: Int { package.providers.count }
    public var parsedSessionsCount: Int { package.sessions.count }
    public var parsedMCPServersCount: Int { package.mcpServers.count }
    public var parsedSkillsCount: Int { package.skills.count }
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
        fileURLs: [URL]
    ) throws -> ThirdPartyImportPreparedResult {
        guard let first = fileURLs.first else { throw ThirdPartyImportError.fileNotReadable }
        guard fileURLs.count > 1 else { return try prepareImport(source: source, fileURL: first) }
        guard source == .openMinis else { return try prepareImport(source: source, fileURL: first) }

        let prepared = try fileURLs.map { try prepareImport(source: source, fileURL: $0) }
        var providerIDs = Set<UUID>()
        var sessionIDs = Set<UUID>()
        var mcpKeys = Set<String>()
        var skillNames = Set<String>()
        let providers = prepared.flatMap(\.package.providers).filter { providerIDs.insert($0.id).inserted }
        let sessions = prepared.flatMap(\.package.sessions).filter { sessionIDs.insert($0.session.id).inserted }
        let mcpServers = prepared.flatMap(\.package.mcpServers).filter { server in
            mcpKeys.insert("\(server.displayName.lowercased())|\(server.humanReadableEndpoint.lowercased())").inserted
        }
        let skills = prepared.flatMap(\.package.skills).filter { skillNames.insert($0.name).inserted }
        var options: SyncOptions = []
        if !providers.isEmpty { options.insert(.providers) }
        if !sessions.isEmpty { options.insert(.sessions) }
        if !mcpServers.isEmpty { options.insert(.mcpServers) }
        if !skills.isEmpty { options.insert(.skills) }
        return ThirdPartyImportPreparedResult(
            source: source,
            package: SyncPackage(
                options: options,
                sourcePlatform: "OpenMinis",
                providers: providers,
                sessions: sessions,
                mcpServers: mcpServers,
                skills: skills
            ),
            warnings: Array(Set(prepared.flatMap(\.warnings))).sorted(),
            recognizedSkillNames: Array(Set(prepared.flatMap(\.recognizedSkillNames))).sorted(),
            containsSensitiveCredentials: prepared.contains(where: \.containsSensitiveCredentials),
            parsedMessagesCount: prepared.reduce(0) { $0 + $1.parsedMessagesCount },
            attachmentPlaceholderCount: prepared.reduce(0) { $0 + $1.attachmentPlaceholderCount },
            degradedItemCount: prepared.reduce(0) { $0 + $1.degradedItemCount }
        )
    }

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

            if source == .openMinis {
                let parsed = try parseOpenMinis(fileURL: fileURL)
                var options: SyncOptions = []
                if !parsed.payload.providers.isEmpty { options.insert(.providers) }
                if !parsed.payload.sessions.isEmpty { options.insert(.sessions) }
                if !parsed.mcpServers.isEmpty { options.insert(.mcpServers) }
                if !parsed.skills.isEmpty { options.insert(.skills) }
                let package = SyncPackage(
                    options: options,
                    sourcePlatform: "OpenMinis",
                    providers: parsed.payload.providers,
                    sessions: parsed.payload.sessions,
                    mcpServers: parsed.mcpServers,
                    skills: parsed.skills
                )
                return ThirdPartyImportPreparedResult(
                    source: source,
                    package: package,
                    warnings: parsed.payload.warnings,
                    recognizedSkillNames: parsed.recognizedSkillNames,
                    containsSensitiveCredentials: parsed.containsSensitiveCredentials,
                    parsedMessagesCount: parsed.messageCount,
                    attachmentPlaceholderCount: parsed.attachmentPlaceholderCount,
                    degradedItemCount: parsed.degradedItemCount
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
            case .openMinis:
                throw ThirdPartyImportError.unsupportedBackupFormat(reason: NSLocalizedString("导入来源未实现。", comment: "Third-party import unsupported source error"))
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

    public static func prepareImportInBackground(
        source: ThirdPartyImportSource,
        fileURL: URL
    ) async throws -> ThirdPartyImportPreparedResult {
        try await Task.detached(priority: .userInitiated) {
            try prepareImport(source: source, fileURL: fileURL)
        }.value
    }

    public static func prepareImportInBackground(
        source: ThirdPartyImportSource,
        fileURLs: [URL]
    ) async throws -> ThirdPartyImportPreparedResult {
        try await Task.detached(priority: .userInitiated) {
            try prepareImport(source: source, fileURLs: fileURLs)
        }.value
    }

    @discardableResult
    public static func importAndApply(
        source: ThirdPartyImportSource,
        fileURL: URL,
        chatService: ChatService = .shared,
        memoryManager: MemoryManager? = nil,
        userDefaults: UserDefaults = .standard
    ) async throws -> ThirdPartyImportReport {
        let prepared = try await prepareImportInBackground(source: source, fileURL: fileURL)
        let summary = await Task.detached(priority: .userInitiated) {
            await SyncEngine.apply(
                package: prepared.package,
                chatService: chatService,
                memoryManager: memoryManager,
                userDefaults: userDefaults
            )
        }.value
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
