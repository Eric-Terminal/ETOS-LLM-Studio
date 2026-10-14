import ETOSCore
import Foundation

enum MacDataImportCategory: String, CaseIterable, Sendable, Identifiable {
    case providers, sessions, backgrounds, memories, mcpServers, audioFiles, imageFiles
    case skills, shortcutTools, worldbooks, feedbackTickets, dailyPulse, usageStats, fontFiles, appStorage
    var id: String { rawValue }
    var option: SyncOptions {
        switch self {
        case .providers: .providers
        case .sessions: .sessions
        case .backgrounds: .backgrounds
        case .memories: .memories
        case .mcpServers: .mcpServers
        case .audioFiles: .audioFiles
        case .imageFiles: .imageFiles
        case .skills: .skills
        case .shortcutTools: .shortcutTools
        case .worldbooks: .worldbooks
        case .feedbackTickets: .feedbackTickets
        case .dailyPulse: .dailyPulse
        case .usageStats: .usageStats
        case .fontFiles: .fontFiles
        case .appStorage: .appStorage
        }
    }
    var title: String {
        switch self {
        case .providers: NSLocalizedString("提供商配置", comment: "")
        case .sessions: NSLocalizedString("会话记录", comment: "")
        case .backgrounds: NSLocalizedString("背景图片", comment: "")
        case .memories: NSLocalizedString("记忆", comment: "")
        case .mcpServers: NSLocalizedString("MCP 服务器", comment: "")
        case .audioFiles: NSLocalizedString("音频文件", comment: "")
        case .imageFiles: NSLocalizedString("图片文件", comment: "")
        case .skills: NSLocalizedString("Agent Skills", comment: "")
        case .shortcutTools: NSLocalizedString("快捷指令工具", comment: "")
        case .worldbooks: NSLocalizedString("世界书", comment: "")
        case .feedbackTickets: NSLocalizedString("反馈工单", comment: "")
        case .dailyPulse: NSLocalizedString("每日脉冲", comment: "")
        case .usageStats: NSLocalizedString("用量统计", comment: "")
        case .fontFiles: NSLocalizedString("字体文件与规则", comment: "")
        case .appStorage: NSLocalizedString("软件设置", comment: "")
        }
    }
    static let selectable: [Self] = [.providers, .sessions, .mcpServers, .skills]
}

struct MacDataImportRow: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
}

struct MacDataImportPreview: Sendable {
    let rows: [MacDataImportRow]
    let warnings: [MacDataImportRow]
    let skillNames: [MacDataImportRow]
    let scopeRows: [MacDataImportCategory]
    let availableScopes: Set<MacDataImportCategory>
    let sensitiveScopes: Set<MacDataImportCategory>
    let fixedScope: String?
    let settingsMayContainCredentials: Bool
    let guideCounts: JSONValue

    init(prepared: ThirdPartyImportPreparedResult, conflicts: MacDataImportConflicts = .empty) {
        let package = prepared.package
        let counts: [MacDataImportCategory: Int] = [
            .providers: package.providers.count, .sessions: package.sessions.count,
            .backgrounds: package.backgrounds.count, .memories: package.memories.count,
            .mcpServers: package.mcpServers.count, .audioFiles: package.audioFiles.count,
            .imageFiles: package.imageFiles.count, .skills: package.skills.count,
            .shortcutTools: package.shortcutTools.count, .worldbooks: package.worldbooks.count,
            .feedbackTickets: package.feedbackTickets.count, .dailyPulse: package.dailyPulseRuns.count,
            .usageStats: package.usageStatsDayBundles.count, .fontFiles: package.fontFiles.count,
            .appStorage: package.appStorageSnapshot == nil && package.globalSystemPrompt == nil ? 0 : 1
        ]
        let categories = MacDataImportCategory.allCases.filter { package.options.contains($0.option) }
        fixedScope = prepared.source == .etosBackup
            ? categories.map(\.title).joined(separator: NSLocalizedString("、", comment: "")) : nil
        scopeRows = MacDataImportCategory.selectable.filter { package.options.contains($0.option) && counts[$0, default: 0] > 0 }
        availableScopes = Set(scopeRows)
        // 只保留是否需要确认的布尔值；任何凭据正文都不进入展示和向导快照。
        var sensitive: Set<MacDataImportCategory> = []
        if package.providers.contains(where: {
            $0.apiKeys.contains(where: { !$0.isEmpty }) || !$0.headerOverrides.isEmpty || $0.proxyConfiguration != nil
        }) { sensitive.insert(.providers) }
        if !package.mcpServers.isEmpty { sensitive.insert(.mcpServers) }
        if prepared.containsSensitiveCredentials { sensitive.formUnion([.providers, .mcpServers]) }
        sensitiveScopes = sensitive.intersection(availableScopes)
        settingsMayContainCredentials = package.options.contains(.appStorage) && package.appStorageSnapshot != nil
        var result = categories.map { MacDataImportRow(id: $0.rawValue, title: $0.title, value: String(counts[$0, default: 0])) }
        if prepared.source == .openMinis {
            result += [
                MacDataImportRow(id: "messages", title: NSLocalizedString("识别到消息", comment: ""), value: String(prepared.parsedMessagesCount)),
                MacDataImportRow(id: "placeholders", title: NSLocalizedString("附件占位", comment: ""), value: String(prepared.attachmentPlaceholderCount)),
                MacDataImportRow(id: "degraded", title: NSLocalizedString("降级项", comment: ""), value: String(prepared.degradedItemCount))
            ]
        }
        if prepared.source != .etosBackup {
            result += [
                MacDataImportRow(id: "provider_conflicts", title: NSLocalizedString("可能冲突提供商", comment: ""), value: String(conflicts.providers)),
                MacDataImportRow(id: "session_conflicts", title: NSLocalizedString("可能冲突会话", comment: ""), value: String(conflicts.sessions)),
                MacDataImportRow(id: "provider_adds", title: NSLocalizedString("预计新增提供商", comment: ""), value: String(max(0, package.providers.count - conflicts.providers))),
                MacDataImportRow(id: "session_adds", title: NSLocalizedString("预计新增会话", comment: ""), value: String(max(0, package.sessions.count - conflicts.sessions)))
            ]
        }
        rows = result
        warnings = prepared.warnings.enumerated().map { MacDataImportRow(id: String($0.offset), title: $0.element, value: "") }
        skillNames = prepared.recognizedSkillNames.enumerated().map { MacDataImportRow(id: String($0.offset), title: $0.element, value: "") }
        var guide = Dictionary(uniqueKeysWithValues: categories.map { ($0.rawValue, JSONValue.int(counts[$0, default: 0])) })
        guide["messages"] = .int(prepared.parsedMessagesCount)
        guide["attachment_placeholders"] = .int(prepared.attachmentPlaceholderCount)
        guide["degraded_items"] = .int(prepared.degradedItemCount)
        guide["warnings"] = .int(prepared.warnings.count)
        guide["possible_provider_conflicts"] = .int(conflicts.providers)
        guide["possible_session_conflicts"] = .int(conflicts.sessions)
        guideCounts = .dictionary(guide)
    }

    func requiresCredentialAcknowledgement(selection: Set<MacDataImportCategory>) -> Bool {
        settingsMayContainCredentials || !sensitiveScopes.isDisjoint(with: fixedScope == nil ? selection : availableScopes)
    }

    static func scopedPackage(_ prepared: ThirdPartyImportPreparedResult, selection: Set<MacDataImportCategory>) throws -> SyncPackage {
        if prepared.source == .etosBackup { return prepared.package }
        let original = prepared.package
        let selected = selection.intersection(Set(MacDataImportCategory.selectable))
        var options: SyncOptions = []
        if selected.contains(.providers), !original.providers.isEmpty { options.insert(.providers) }
        if selected.contains(.sessions), !original.sessions.isEmpty { options.insert(.sessions) }
        if selected.contains(.mcpServers), !original.mcpServers.isEmpty { options.insert(.mcpServers) }
        if selected.contains(.skills), !original.skills.isEmpty { options.insert(.skills) }
        options.formIntersection(original.options)
        guard !options.isEmpty else { throw ThirdPartyImportError.noImportableContent }
        // 会话的标签及媒体引用必须与正文一起保留，不能因缩小范围而制造悬空附件。
        return SyncPackage(options: options, sourcePlatform: original.sourcePlatform,
            providers: options.contains(.providers) ? original.providers : [],
            sessionTags: options.contains(.sessions) ? original.sessionTags : [],
            sessions: options.contains(.sessions) ? original.sessions : [],
            mcpServers: options.contains(.mcpServers) ? original.mcpServers : [],
            audioFiles: options.contains(.sessions) ? original.audioFiles : [],
            imageFiles: options.contains(.sessions) ? original.imageFiles : [],
            skills: options.contains(.skills) ? original.skills : [])
    }
}

struct MacDataImportConflicts: Sendable {
    let providers: Int
    let sessions: Int
    static let empty = Self(providers: 0, sessions: 0)

    static func load(for package: SyncPackage) throws -> Self {
        let localProviders = package.providers.isEmpty ? [] : ConfigLoader.loadProviders()
        let signatures = Set(localProviders.map(providerSignature))
        let providerConflicts = package.providers.filter { signatures.contains(providerSignature($0)) }.count
        try Task.checkCancellation()
        let locals = package.sessions.isEmpty ? [] : Persistence.loadChatSessions().filter { !$0.isTemporary }
        let localIDs = Set(locals.map(\.id))
        var sessionSignatures: Set<String> = []
        for session in locals {
            try Task.checkCancellation()
            sessionSignatures.insert("\(session.name.lowercased())|\(Persistence.loadMessageCount(for: session.id))")
        }
        let sessionConflicts = package.sessions.filter {
            localIDs.contains($0.session.id) || sessionSignatures.contains("\($0.session.name.lowercased())|\($0.messages.count)")
        }.count
        return Self(providers: providerConflicts, sessions: sessionConflicts)
    }

    private static func providerSignature(_ provider: Provider) -> String {
        [provider.name.lowercased(), provider.baseURL.lowercased(), provider.apiFormat.lowercased(),
            provider.models.map(\.modelName).sorted().joined(separator: ",").lowercased()].joined(separator: "|")
    }
}

struct MacDataImportReport: Sendable {
    let rows: [MacDataImportRow]
    let warnings: [MacDataImportRow]
    let guideSummary: JSONValue

    init(summary: SyncMergeSummary, options: SyncOptions, warnings: [String] = []) {
        self.warnings = warnings.enumerated().map { MacDataImportRow(id: String($0.offset), title: $0.element, value: "") }
        let counts: [(MacDataImportCategory, Int, Int)] = [
            (.providers, summary.importedProviders, summary.skippedProviders), (.sessions, summary.importedSessions, summary.skippedSessions),
            (.backgrounds, summary.importedBackgrounds, summary.skippedBackgrounds), (.memories, summary.importedMemories, summary.skippedMemories),
            (.mcpServers, summary.importedMCPServers, summary.skippedMCPServers), (.audioFiles, summary.importedAudioFiles, summary.skippedAudioFiles),
            (.imageFiles, summary.importedImageFiles, summary.skippedImageFiles), (.skills, summary.importedSkills, summary.skippedSkills),
            (.shortcutTools, summary.importedShortcutTools, summary.skippedShortcutTools), (.worldbooks, summary.importedWorldbooks, summary.skippedWorldbooks),
            (.feedbackTickets, summary.importedFeedbackTickets, summary.skippedFeedbackTickets), (.dailyPulse, summary.importedDailyPulseRuns, summary.skippedDailyPulseRuns),
            (.usageStats, summary.importedUsageEvents, summary.skippedUsageEvents),
            (.fontFiles, summary.importedFontFiles + summary.importedFontRouteConfigurations, summary.skippedFontFiles + summary.skippedFontRouteConfigurations),
            (.appStorage, summary.importedAppStorageValues, summary.skippedAppStorageValues)
        ]
        let included = counts.filter { options.contains($0.0.option) || $0.1 > 0 || $0.2 > 0 }
        rows = included.map { MacDataImportRow(id: $0.0.rawValue, title: $0.0.title,
            value: String(format: NSLocalizedString("新增 %d，跳过 %d", comment: ""), $0.1, $0.2)) }
        guideSummary = .dictionary(Dictionary(uniqueKeysWithValues: included.map {
            ($0.0.rawValue, .dictionary(["imported": .int($0.1), "skipped": .int($0.2)]))
        }))
    }
}
