// ============================================================================
// ThirdPartyImportView.swift
// ============================================================================
// 导入数据页面 (iOS)
// - 提供来源选择 + 文件解析预览 + 勾选导入
// - 导入后展示合并摘要
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import Shared

struct ThirdPartyImportView: View {
    @State private var selectedSource: ThirdPartyImportSource = .etosBackup
    @State private var isFileImporterPresented: Bool = false
    @State private var isPreparing: Bool = false
    @State private var isImporting: Bool = false
    @State private var selectedFileName: String = ""
    @State private var preparedResult: ThirdPartyImportPreparedResult?
    @State private var conflictPreview: ConflictPreview = .empty
    @State private var includeProviders: Bool = true
    @State private var includeSessions: Bool = true
    @State private var importReport: ThirdPartyImportReport?
    @State private var importError: String?

    var body: some View {
        List {
            Section(NSLocalizedString("导入来源", comment: "Third-party import source section title")) {
                Picker(
                    NSLocalizedString("数据来源", comment: "Third-party data source picker title"),
                    selection: $selectedSource
                ) {
                    ForEach(ThirdPartyImportSource.allCases, id: \.self) { source in
                        Text(source.displayName)
                            .tag(source)
                    }
                }
                .pickerStyle(.navigationLink)

                Text(sourceHint(for: selectedSource))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("导入操作", comment: "Third-party import action section title")) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label(
                        NSLocalizedString("选择文件并解析", comment: "Select file and parse button"),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .disabled(isBusy)

                if !selectedFileName.isEmpty {
                    row(
                        title: NSLocalizedString("最近选择", comment: "Last selected file row title"),
                        value: selectedFileName
                    )
                }

                if isPreparing {
                    progressRow(text: NSLocalizedString("正在解析备份内容...", comment: "Preparing progress text"))
                }

                if isImporting {
                    progressRow(text: NSLocalizedString("正在导入并合并数据...", comment: "Importing progress text"))
                }
            }

            if let preparedResult {
                Section(NSLocalizedString("解析预览", comment: "Prepared import preview title")) {
                    if preparedResult.source == .etosBackup {
                        row(
                            title: NSLocalizedString("导出同步项", comment: "ETOS package sync options row"),
                            value: syncOptionSummary(preparedResult.package.options)
                        )
                    }
                    row(
                        title: NSLocalizedString("识别到提供商", comment: "Parsed providers row"),
                        value: "\(preparedResult.parsedProvidersCount)"
                    )
                    row(
                        title: NSLocalizedString("识别到会话", comment: "Parsed sessions row"),
                        value: "\(preparedResult.parsedSessionsCount)"
                    )
                    if preparedResult.source != .etosBackup {
                        row(
                            title: NSLocalizedString("可能冲突提供商", comment: "Potential provider conflicts"),
                            value: "\(conflictPreview.providerConflicts)"
                        )
                        row(
                            title: NSLocalizedString("可能冲突会话", comment: "Potential session conflicts"),
                            value: "\(conflictPreview.sessionConflicts)"
                        )
                        row(
                            title: NSLocalizedString("预计新增提供商", comment: "Estimated new providers"),
                            value: "\(conflictPreview.providerAdds)"
                        )
                        row(
                            title: NSLocalizedString("预计新增会话", comment: "Estimated new sessions"),
                            value: "\(conflictPreview.sessionAdds)"
                        )
                    }
                }

                Section {
                    if preparedResult.source == .etosBackup {
                        Text("ETOS 数据包会按导出时勾选的同步项执行全量导入。")
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        if preparedResult.parsedProvidersCount > 0 {
                            Toggle(
                                NSLocalizedString("导入提供商配置", comment: "Import providers toggle"),
                                isOn: $includeProviders
                            )
                        }

                        if preparedResult.parsedSessionsCount > 0 {
                            Toggle(
                                NSLocalizedString("导入会话记录", comment: "Import sessions toggle"),
                                isOn: $includeSessions
                            )
                        }
                    }

                    Button {
                        startImport()
                    } label: {
                        Label(
                            NSLocalizedString("确认导入", comment: "Confirm import button"),
                            systemImage: "square.and.arrow.down.on.square"
                        )
                    }
                    .disabled(isBusy || !canStartImport)
                } header: {
                    Text(NSLocalizedString("导入范围", comment: "Import scope section title"))
                } footer: {
                    if preparedResult.source == .etosBackup {
                        Text("导入后会立即执行与“同步与备份”一致的合并策略。")
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(NSLocalizedString("冲突预览为本地启发式估算，最终结果以导入完成后的统计为准。", comment: "Import scope footer"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !preparedResult.warnings.isEmpty {
                    Section(NSLocalizedString("解析提示", comment: "Prepared warnings section title")) {
                        ForEach(preparedResult.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let importReport {
                Section(NSLocalizedString("最近导入结果", comment: "Latest import summary section title")) {
                    row(
                        title: NSLocalizedString("本次解析提供商", comment: "Parsed providers in selected scope row"),
                        value: "\(importReport.parsedProvidersCount)"
                    )
                    row(
                        title: NSLocalizedString("本次解析会话", comment: "Parsed sessions in selected scope row"),
                        value: "\(importReport.parsedSessionsCount)"
                    )
                    row(
                        title: NSLocalizedString("新增提供商", comment: "Imported providers row"),
                        value: "\(importReport.summary.importedProviders)"
                    )
                    row(
                        title: NSLocalizedString("跳过提供商", comment: "Skipped providers row"),
                        value: "\(importReport.summary.skippedProviders)"
                    )
                    row(
                        title: NSLocalizedString("新增会话", comment: "Imported sessions row"),
                        value: "\(importReport.summary.importedSessions)"
                    )
                    row(
                        title: NSLocalizedString("跳过会话", comment: "Skipped sessions row"),
                        value: "\(importReport.summary.skippedSessions)"
                    )
                }

                if !importReport.warnings.isEmpty {
                    Section(NSLocalizedString("导入提示", comment: "Import warnings section title")) {
                        ForEach(importReport.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let importError, !importError.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "Import error section title")) {
                    Text(importError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("导入数据", comment: "Import data nav title"))
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .onChange(of: selectedSource) { _, _ in
            resetPreparedState()
        }
    }

    private var isBusy: Bool {
        isPreparing || isImporting
    }

    private var canStartImport: Bool {
        guard let preparedResult else { return false }
        if preparedResult.source == .etosBackup {
            return !preparedResult.package.options.isEmpty
        }
        let hasProviderSelection = includeProviders && preparedResult.parsedProvidersCount > 0
        let hasSessionSelection = includeSessions && preparedResult.parsedSessionsCount > 0
        return hasProviderSelection || hasSessionSelection
    }

    private var allowedContentTypes: [UTType] {
        var identifiers: Set<String> = []
        var types: [UTType] = []

        func append(_ type: UTType) {
            if identifiers.insert(type.identifier).inserted {
                types.append(type)
            }
        }

        append(.json)
        append(.data)
        append(.folder)

        if selectedSource == .cherryStudio || selectedSource == .rikkahub || selectedSource == .kelivo {
            if let zipType = UTType(filenameExtension: "zip") {
                append(zipType)
            }
            if let bakType = UTType(filenameExtension: "bak") {
                append(bakType)
            }
        }

        return types
    }

    private func sourceHint(for source: ThirdPartyImportSource) -> String {
        switch source {
        case .etosBackup:
            return NSLocalizedString("支持导入 ETOS 导出的 JSON 数据包（包含“同步与备份”页导出的备份）。", comment: "ETOS source hint")
        case .cherryStudio:
            return NSLocalizedString("支持 Cherry Studio 的 .json 或解压后的备份目录；若是 .zip / .bak，请先解压后再导入。", comment: "Cherry source hint")
        case .rikkahub:
            return NSLocalizedString("支持 RikkaHub 的 settings.json（可直接选文件或解压目录，当前先导入提供商配置）。", comment: "Rikka source hint")
        case .kelivo:
            return NSLocalizedString("支持 Kelivo 的 settings.json + chats.json（建议选择解压后的目录一次导入）。", comment: "Kelivo source hint")
        case .chatgpt:
            return NSLocalizedString("支持 ChatGPT 官方 conversations.json（可直接选文件或包含该文件的目录）。", comment: "ChatGPT source hint")
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            selectedFileName = fileURL.lastPathComponent
            prepareImport(fileURL: fileURL, source: selectedSource)

        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func prepareImport(fileURL: URL, source: ThirdPartyImportSource) {
        isPreparing = true
        importError = nil
        importReport = nil
        preparedResult = nil
        conflictPreview = .empty

        Task {
            do {
                let prepared = try ThirdPartyImportService.prepareImport(
                    source: source,
                    fileURL: fileURL
                )
                let preview = buildConflictPreview(for: prepared.package)
                await MainActor.run {
                    preparedResult = prepared
                    includeProviders = prepared.package.options.contains(.providers)
                    includeSessions = prepared.package.options.contains(.sessions)
                    conflictPreview = preview
                    isPreparing = false
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isPreparing = false
                }
            }
        }
    }

    private func startImport() {
        guard let preparedResult else { return }

        if preparedResult.source == .etosBackup {
            guard !preparedResult.package.options.isEmpty else {
                importError = NSLocalizedString("导出包没有包含可导入的数据。", comment: "ETOS package empty options")
                return
            }

            isImporting = true
            importError = nil

            Task {
                let summary = await SyncEngine.apply(package: preparedResult.package)
                let report = ThirdPartyImportReport(
                    source: preparedResult.source,
                    parsedProvidersCount: preparedResult.parsedProvidersCount,
                    parsedSessionsCount: preparedResult.parsedSessionsCount,
                    summary: summary,
                    warnings: preparedResult.warnings
                )

                await MainActor.run {
                    importReport = report
                    isImporting = false
                }
            }
            return
        }

        var options: SyncOptions = []
        let providers: [Provider]
        let sessions: [SyncedSession]

        if includeProviders, preparedResult.parsedProvidersCount > 0 {
            options.insert(.providers)
            providers = preparedResult.package.providers
        } else {
            providers = []
        }

        if includeSessions, preparedResult.parsedSessionsCount > 0 {
            options.insert(.sessions)
            sessions = preparedResult.package.sessions
        } else {
            sessions = []
        }

        guard !options.isEmpty else {
            importError = NSLocalizedString("请至少选择一个导入项。", comment: "No selected import scope")
            return
        }

        isImporting = true
        importError = nil

        Task {
            let scopedPackage = SyncPackage(
                options: options,
                providers: providers,
                sessions: sessions
            )

            let summary = await SyncEngine.apply(package: scopedPackage)
            let report = ThirdPartyImportReport(
                source: preparedResult.source,
                parsedProvidersCount: providers.count,
                parsedSessionsCount: sessions.count,
                summary: summary,
                warnings: preparedResult.warnings
            )

            await MainActor.run {
                importReport = report
                isImporting = false
            }
        }
    }

    private func resetPreparedState() {
        preparedResult = nil
        importReport = nil
        importError = nil
        conflictPreview = .empty
        includeProviders = true
        includeSessions = true
    }

    private func syncOptionSummary(_ options: SyncOptions) -> String {
        var items: [String] = []
        if options.contains(.providers) { items.append("提供商配置") }
        if options.contains(.sessions) { items.append("会话记录") }
        if options.contains(.backgrounds) { items.append("背景图片") }
        if options.contains(.memories) { items.append("记忆") }
        if options.contains(.mcpServers) { items.append("MCP 服务器") }
        if options.contains(.audioFiles) { items.append("音频文件") }
        if options.contains(.imageFiles) { items.append("图片文件") }
        if options.contains(.skills) { items.append("Agent Skills") }
        if options.contains(.shortcutTools) { items.append("快捷指令工具") }
        if options.contains(.worldbooks) { items.append("世界书") }
        if options.contains(.feedbackTickets) { items.append("反馈工单") }
        if options.contains(.dailyPulse) { items.append("每日脉冲") }
        if options.contains(.usageStats) { items.append("用量统计") }
        if options.contains(.fontFiles) { items.append("字体文件与规则") }
        if options.contains(.appStorage) { items.append("软件设置") }
        return items.isEmpty ? "无" : items.joined(separator: "、")
    }

    private func buildConflictPreview(for package: SyncPackage) -> ConflictPreview {
        let providerConflicts = estimateProviderConflicts(incoming: package.providers)
        let providerAdds = max(0, package.providers.count - providerConflicts)

        let sessionConflicts = estimateSessionConflicts(incoming: package.sessions)
        let sessionAdds = max(0, package.sessions.count - sessionConflicts)

        return ConflictPreview(
            providerConflicts: providerConflicts,
            sessionConflicts: sessionConflicts,
            providerAdds: providerAdds,
            sessionAdds: sessionAdds
        )
    }

    private func estimateProviderConflicts(incoming: [Provider]) -> Int {
        guard !incoming.isEmpty else { return 0 }
        let locals = ConfigLoader.loadProviders()
        let localSignatures = Set(locals.map(providerSignature))
        return incoming.reduce(into: 0) { count, provider in
            if localSignatures.contains(providerSignature(provider)) {
                count += 1
            }
        }
    }

    private func estimateSessionConflicts(incoming: [SyncedSession]) -> Int {
        guard !incoming.isEmpty else { return 0 }

        let localSessions = Persistence.loadChatSessions().filter { !$0.isTemporary }
        let localSessionIDs = Set(localSessions.map(\.id))

        var localSignatures: Set<String> = []
        localSignatures.reserveCapacity(localSessions.count)
        for session in localSessions {
            let messages = Persistence.loadMessages(for: session.id)
            localSignatures.insert(sessionSignature(name: session.name, messages: messages))
        }

        return incoming.reduce(into: 0) { count, incomingSession in
            if localSessionIDs.contains(incomingSession.session.id) {
                count += 1
                return
            }
            let signature = sessionSignature(
                name: incomingSession.session.name,
                messages: incomingSession.messages
            )
            if localSignatures.contains(signature) {
                count += 1
            }
        }
    }

    private func providerSignature(_ provider: Provider) -> String {
        [
            provider.name.lowercased(),
            provider.baseURL.lowercased(),
            provider.apiFormat.lowercased(),
            provider.models.map(\.modelName).sorted().joined(separator: ",").lowercased()
        ].joined(separator: "|")
    }

    private func sessionSignature(name: String, messages: [ChatMessage]) -> String {
        let first = messages.first
        let last = messages.last
        let firstSnippet = String((first?.content ?? "").prefix(80)).lowercased()
        let lastSnippet = String((last?.content ?? "").prefix(80)).lowercased()

        return [
            name.lowercased(),
            "\(messages.count)",
            first?.role.rawValue ?? "",
            last?.role.rawValue ?? "",
            firstSnippet,
            lastSnippet
        ].joined(separator: "|")
    }

    @ViewBuilder
    private func progressRow(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ConflictPreview {
    var providerConflicts: Int
    var sessionConflicts: Int
    var providerAdds: Int
    var sessionAdds: Int

    static let empty = ConflictPreview(
        providerConflicts: 0,
        sessionConflicts: 0,
        providerAdds: 0,
        sessionAdds: 0
    )
}
